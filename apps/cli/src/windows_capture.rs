//! Windows process-loopback capture probe using the documented WASAPI path.

use anyhow::{Context, Result, bail};
use serde::Serialize;
use std::{
    mem::{ManuallyDrop, size_of},
    pin::Pin,
    ptr, slice,
    sync::{Arc, Condvar, Mutex},
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{CloseHandle, WAIT_OBJECT_0},
        Media::Audio::{
            AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY, AUDCLNT_BUFFERFLAGS_SILENT,
            AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK, AUDCLNT_STREAMFLAGS_LOOPBACK,
            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, AUDIOCLIENT_ACTIVATION_PARAMS,
            AUDIOCLIENT_ACTIVATION_PARAMS_0, AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
            AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS, ActivateAudioInterfaceAsync,
            IActivateAudioInterfaceAsyncOperation, IActivateAudioInterfaceCompletionHandler,
            IActivateAudioInterfaceCompletionHandler_Impl, IAudioCaptureClient, IAudioClient,
            PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE,
            PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
            VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, WAVE_FORMAT_PCM, WAVEFORMATEX,
        },
        System::{
            Com::{
                BLOB, COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize,
                StructuredStorage::{
                    PROPVARIANT, PROPVARIANT_0, PROPVARIANT_0_0, PROPVARIANT_0_0_0,
                },
            },
            Threading::{
                AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, CreateEventW,
                GetCurrentProcessId, WaitForSingleObject,
            },
            Variant::VT_BLOB,
        },
    },
    core::{HRESULT, IUnknown, Interface, Ref, implement, w},
};

#[derive(Clone, Debug)]
pub struct CaptureBlock {
    pub pcm: Vec<u8>,
    pub frames: u32,
    pub device_position: u64,
    pub qpc_position: u64,
    pub discontinuity: bool,
}

#[derive(Debug)]
pub struct CaptureResult {
    pub blocks: Vec<CaptureBlock>,
    pub total_frames: u64,
    pub discontinuities: u64,
}

#[derive(Debug, Serialize)]
pub struct CaptureReport {
    pub pid: u32,
    pub blocks: usize,
    pub frames: u64,
    pub discontinuities: u64,
    pub silent_frames: u64,
    pub peak: f64,
    pub first_device_position: Option<u64>,
    pub last_device_position: Option<u64>,
    pub first_qpc_position: Option<u64>,
    pub last_qpc_position: Option<u64>,
    pub output: String,
}

type ActivationShared = Arc<(Mutex<bool>, Condvar)>;

#[implement(IActivateAudioInterfaceCompletionHandler)]
struct ActivationHandler {
    shared: ActivationShared,
}

impl IActivateAudioInterfaceCompletionHandler_Impl for ActivationHandler_Impl {
    fn ActivateCompleted(
        &self,
        _operation: Ref<IActivateAudioInterfaceAsyncOperation>,
    ) -> windows::core::Result<()> {
        let (lock, condition) = &*self.shared;
        *lock.lock().expect("activation result mutex poisoned") = true;
        condition.notify_one();
        Ok(())
    }
}

struct ComGuard;
impl Drop for ComGuard {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

struct HandleGuard(windows::Win32::Foundation::HANDLE);
impl Drop for HandleGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

struct MmcssGuard(windows::Win32::Foundation::HANDLE);
impl Drop for MmcssGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = AvRevertMmThreadCharacteristics(self.0);
        }
    }
}

pub fn capture_process(pid: u32, duration: Duration) -> Result<CaptureResult> {
    let mut blocks = Vec::new();
    let (total_frames, discontinuities) =
        capture_process_with(pid, duration, |block| blocks.push(block))?;
    Ok(CaptureResult {
        blocks,
        total_frames,
        discontinuities,
    })
}

pub fn capture_process_stream(
    pid: u32,
    duration: Duration,
    sender: tokio::sync::broadcast::Sender<CaptureBlock>,
) -> Result<(u64, u64)> {
    capture_with(pid, false, duration, |block| {
        // A broadcast ring is deliberately bounded: if the network consumer
        // falls behind, the oldest capture blocks expire instead of growing
        // latency without limit.
        let _ = sender.send(block);
    })
}

pub fn capture_system_stream(
    duration: Duration,
    sender: tokio::sync::broadcast::Sender<CaptureBlock>,
) -> Result<(u64, u64)> {
    let pid = unsafe { GetCurrentProcessId() };
    capture_with(pid, true, duration, |block| {
        // Excluding this process tree prevents Sonara from recapturing its own
        // internal host audio while retaining every other audible process.
        let _ = sender.send(block);
    })
}

fn capture_process_with(
    pid: u32,
    duration: Duration,
    consume: impl FnMut(CaptureBlock),
) -> Result<(u64, u64)> {
    capture_with(pid, false, duration, consume)
}

fn capture_with(
    pid: u32,
    exclude_process_tree: bool,
    duration: Duration,
    mut consume: impl FnMut(CaptureBlock),
) -> Result<(u64, u64)> {
    eprintln!("WASAPI: initializing COM");
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
    }
    let _com = ComGuard;
    let mut task_index = 0u32;
    let mmcss = unsafe { AvSetMmThreadCharacteristicsW(w!("Pro Audio"), &mut task_index) }
        .context("joining the Windows Pro Audio scheduling class")?;
    let _mmcss = MmcssGuard(mmcss);
    if exclude_process_tree {
        eprintln!("WASAPI: activating system loopback (excluding Sonara PID {pid})");
    } else {
        eprintln!("WASAPI: activating process loopback for PID {pid}");
    }
    let audio_client = activate_process_client(pid, exclude_process_tree)?;
    eprintln!("WASAPI: activation complete");
    let format = pcm_format();
    unsafe {
        audio_client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK
                | AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            0,
            0,
            &format,
            None,
        )?;
    }
    eprintln!("WASAPI: client initialized");
    let event = unsafe { CreateEventW(None, false, false, None)? };
    let event = HandleGuard(event);
    unsafe {
        audio_client.SetEventHandle(event.0)?;
    }
    let capture: IAudioCaptureClient = unsafe { audio_client.GetService()? };
    unsafe {
        audio_client.Start()?;
    }
    eprintln!("WASAPI: capture started");

    let started = Instant::now();
    let mut total_frames = 0u64;
    let mut discontinuities = 0u64;
    while started.elapsed() < duration {
        let wait = unsafe { WaitForSingleObject(event.0, 1000) };
        if wait != WAIT_OBJECT_0 {
            continue;
        }
        loop {
            let next = unsafe { capture.GetNextPacketSize()? };
            if next == 0 {
                break;
            }
            let mut data = ptr::null_mut();
            let mut frames = 0u32;
            let mut flags = 0u32;
            let mut device_position = 0u64;
            let mut qpc_position = 0u64;
            unsafe {
                capture.GetBuffer(
                    &mut data,
                    &mut frames,
                    &mut flags,
                    Some(&mut device_position),
                    Some(&mut qpc_position),
                )?;
            }
            let byte_count = frames as usize * format.nBlockAlign as usize;
            let silent = flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0;
            let pcm = if silent {
                vec![0; byte_count]
            } else {
                if data.is_null() {
                    unsafe {
                        capture.ReleaseBuffer(frames)?;
                    }
                    bail!("WASAPI returned a null non-silent buffer");
                }
                unsafe { slice::from_raw_parts(data, byte_count).to_vec() }
            };
            let discontinuity = flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY.0 as u32 != 0;
            unsafe {
                capture.ReleaseBuffer(frames)?;
            }
            total_frames += u64::from(frames);
            discontinuities += u64::from(discontinuity);
            consume(CaptureBlock {
                pcm,
                frames,
                device_position,
                qpc_position,
                discontinuity,
            });
        }
    }
    unsafe {
        audio_client.Stop()?;
    }
    eprintln!("WASAPI: capture stopped with {total_frames} frames");
    Ok((total_frames, discontinuities))
}

pub fn capture_process_to_wav(
    pid: u32,
    duration: Duration,
    output: &std::path::Path,
) -> Result<CaptureReport> {
    let capture = capture_process(pid, duration)?;
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: 48_000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(output, spec)
        .with_context(|| format!("creating {}", output.display()))?;
    let mut silent_frames = 0u64;
    let mut observed_discontinuities = 0u64;
    let mut peak = 0.0f64;
    for block in &capture.blocks {
        let block_silent = block.pcm.iter().all(|byte| *byte == 0);
        observed_discontinuities += u64::from(block.discontinuity);
        if block_silent {
            silent_frames += u64::from(block.frames);
        }
        for bytes in block.pcm.chunks_exact(2) {
            let sample = i16::from_le_bytes([bytes[0], bytes[1]]);
            peak = peak.max((f64::from(sample) / f64::from(i16::MAX)).abs());
            writer.write_sample(sample)?;
        }
    }
    writer.finalize()?;
    debug_assert_eq!(observed_discontinuities, capture.discontinuities);
    Ok(CaptureReport {
        pid,
        blocks: capture.blocks.len(),
        frames: capture.total_frames,
        discontinuities: capture.discontinuities,
        silent_frames,
        peak,
        first_device_position: capture.blocks.first().map(|block| block.device_position),
        last_device_position: capture.blocks.last().map(|block| block.device_position),
        first_qpc_position: capture.blocks.first().map(|block| block.qpc_position),
        last_qpc_position: capture.blocks.last().map(|block| block.qpc_position),
        output: output.display().to_string(),
    })
}

fn activate_process_client(pid: u32, exclude_process_tree: bool) -> Result<IAudioClient> {
    let mut activation = AUDIOCLIENT_ACTIVATION_PARAMS {
        ActivationType: AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
        Anonymous: AUDIOCLIENT_ACTIVATION_PARAMS_0 {
            ProcessLoopbackParams: AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
                TargetProcessId: pid,
                ProcessLoopbackMode: if exclude_process_tree {
                    PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE
                } else {
                    PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE
                },
            },
        },
    };
    let pinned_activation = Pin::new(&mut activation);
    let raw_params = PROPVARIANT {
        Anonymous: PROPVARIANT_0 {
            Anonymous: ManuallyDrop::new(PROPVARIANT_0_0 {
                vt: VT_BLOB,
                wReserved1: 0,
                wReserved2: 0,
                wReserved3: 0,
                Anonymous: PROPVARIANT_0_0_0 {
                    blob: BLOB {
                        cbSize: size_of::<AUDIOCLIENT_ACTIVATION_PARAMS>() as u32,
                        pBlobData: std::ptr::from_mut(pinned_activation.get_mut()).cast(),
                    },
                },
            }),
        },
    };
    let params = ManuallyDrop::new(raw_params);
    let pinned_params = Pin::new(&params);

    let shared: ActivationShared = Arc::new((Mutex::new(false), Condvar::new()));
    let handler: IActivateAudioInterfaceCompletionHandler = ActivationHandler {
        shared: shared.clone(),
    }
    .into();
    let operation = unsafe {
        ActivateAudioInterfaceAsync(
            VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
            &IAudioClient::IID,
            Some(std::ptr::from_ref(pinned_params.get_ref())),
            &handler,
        )?
    };
    let (lock, condition) = &*shared;
    let completed = lock.lock().expect("activation result mutex poisoned");
    let (completed, timeout) = condition
        .wait_timeout_while(completed, Duration::from_secs(10), |completed| !*completed)
        .expect("activation result mutex poisoned");
    if timeout.timed_out() || !*completed {
        bail!("process-loopback activation timed out");
    }
    drop(completed);
    let mut activation_result = HRESULT::default();
    let mut interface: Option<IUnknown> = None;
    unsafe {
        operation.GetActivateResult(&mut activation_result, &mut interface)?;
    }
    activation_result.ok()?;
    interface
        .context("activation returned no audio interface")?
        .cast::<IAudioClient>()
        .context("activated interface is not an IAudioClient")
}

fn pcm_format() -> WAVEFORMATEX {
    WAVEFORMATEX {
        wFormatTag: WAVE_FORMAT_PCM as u16,
        nChannels: 2,
        nSamplesPerSec: 48_000,
        nAvgBytesPerSec: 48_000 * 4,
        nBlockAlign: 4,
        wBitsPerSample: 16,
        cbSize: 0,
    }
}
