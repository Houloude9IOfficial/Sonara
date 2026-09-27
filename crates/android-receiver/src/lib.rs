use anyhow::{Context, Result, bail};
use jni::{
    JNIEnv,
    objects::{JClass, JString},
    sys::{JNI_FALSE, JNI_TRUE, jboolean, jstring},
};
use libloading::Library;
use quinn::crypto::rustls::QuicClientConfig;
use rustls::{RootCertStore, pki_types::CertificateDer};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sonara_engine::{
    CHANNELS, LOGICAL_SAMPLE_RATE,
    invitation::Invitation,
    packet::{AudioPacket, PCM16_KIND},
};
use std::{
    collections::BTreeMap,
    net::SocketAddr,
    sync::atomic::{AtomicBool, Ordering},
    sync::{LazyLock, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::time::timeout;
use uuid::Uuid;

const ALPN: &[u8] = b"sonara/1";
const CONTROL_LIMIT: usize = 64 * 1024;
const STREAM_ID: u32 = 1;

static RUNNING: AtomicBool = AtomicBool::new(false);
static STOP: AtomicBool = AtomicBool::new(false);
static STATUS: LazyLock<Mutex<ReceiverStatus>> =
    LazyLock::new(|| Mutex::new(ReceiverStatus::default()));

#[derive(Clone, Default, Serialize)]
struct ReceiverStatus {
    state: String,
    packets_received: u64,
    packets_lost: u64,
    invalid_packets: u64,
    redundant_packets: u64,
    first_sequence: Option<u32>,
    last_sequence: Option<u32>,
    first_source_time_ns: Option<u64>,
    last_source_time_ns: Option<u64>,
    frames_rendered: u64,
    output_underruns: u64,
    output_dropped_frames: u64,
    output_silence_frames: u64,
    rebuffer_events: u64,
    rate_correction_ppm: f64,
    buffered_frames: u64,
    output_sample_rate: i32,
    output_channels: i32,
    output_frames_per_burst: i32,
    output_device_id: i32,
    output_performance_mode: i32,
    output_sharing_mode: i32,
    clock_uncertainty_ms: Option<f64>,
    target_buffer_ms: f64,
    adaptive_buffer_ms: f64,
    packet_duration_ms: f64,
    mode: String,
    profile: String,
    error: Option<String>,
}

#[derive(Serialize)]
struct PairRequest {
    invitation_id: Uuid,
    token: Vec<u8>,
    receiver_name: String,
}

#[derive(Deserialize)]
struct PairResponse {
    accepted: bool,
    message: String,
    sample_rate: u32,
    channels: u16,
    frame_count: u16,
    epoch: u32,
    clock_probes: u16,
    target_buffer_frames: u32,
    max_reorder_packets: u16,
    mode: String,
    profile: String,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClockControl {
    Request {
        probe_id: u64,
        t1_ns: u64,
    },
    Response {
        probe_id: u64,
        t1_ns: u64,
        t2_ns: u64,
        t3_ns: u64,
    },
    Ready {
        rate: f64,
        offset_seconds: f64,
        uncertainty_ms: f64,
        samples: usize,
        start_host_time_ns: u64,
    },
    PlaybackReady,
}

type AudioStart = unsafe extern "C" fn(*const i16, i32, i32) -> i32;
type AudioStop = unsafe extern "C" fn();
type AudioWrite = unsafe extern "C" fn(*const i16, i32) -> i32;
type AudioMetric = unsafe extern "C" fn() -> u64;
type AudioDisconnected = unsafe extern "C" fn() -> i32;
type AudioCorrection = unsafe extern "C" fn() -> f64;
type AudioI32 = unsafe extern "C" fn() -> i32;
type AudioReset = unsafe extern "C" fn();

struct AudioApi {
    _library: Library,
    start: AudioStart,
    stop: AudioStop,
    write: AudioWrite,
    rendered: AudioMetric,
    underruns: AudioMetric,
    dropped: AudioMetric,
    silence_frames: AudioMetric,
    rebuffer_events: AudioMetric,
    reset_quality: AudioReset,
    disconnected: AudioDisconnected,
    correction: AudioCorrection,
    buffered: AudioMetric,
    sample_rate: AudioI32,
    channels: AudioI32,
    frames_per_burst: AudioI32,
    device_id: AudioI32,
    performance_mode: AudioI32,
    sharing_mode: AudioI32,
    target_frames: AudioI32,
}

impl AudioApi {
    fn load() -> Result<Self> {
        unsafe {
            let library = Library::new("libsonara_audio.so")?;
            let start = *library.get::<AudioStart>(b"sonara_audio_start\0")?;
            let stop = *library.get::<AudioStop>(b"sonara_audio_stop\0")?;
            let write = *library.get::<AudioWrite>(b"sonara_audio_write\0")?;
            let rendered = *library.get::<AudioMetric>(b"sonara_audio_rendered_frames\0")?;
            let underruns = *library.get::<AudioMetric>(b"sonara_audio_underruns\0")?;
            let dropped = *library.get::<AudioMetric>(b"sonara_audio_dropped_frames\0")?;
            let silence_frames = *library.get::<AudioMetric>(b"sonara_audio_silence_frames\0")?;
            let rebuffer_events = *library.get::<AudioMetric>(b"sonara_audio_rebuffer_events\0")?;
            let reset_quality =
                *library.get::<AudioReset>(b"sonara_audio_reset_quality_metrics\0")?;
            let disconnected = *library.get::<AudioDisconnected>(b"sonara_audio_disconnected\0")?;
            let correction = *library.get::<AudioCorrection>(b"sonara_audio_correction_ppm\0")?;
            let buffered = *library.get::<AudioMetric>(b"sonara_audio_buffered_frames\0")?;
            let sample_rate = *library.get::<AudioI32>(b"sonara_audio_output_sample_rate\0")?;
            let channels = *library.get::<AudioI32>(b"sonara_audio_output_channels\0")?;
            let frames_per_burst = *library.get::<AudioI32>(b"sonara_audio_frames_per_burst\0")?;
            let device_id = *library.get::<AudioI32>(b"sonara_audio_output_device_id\0")?;
            let performance_mode = *library.get::<AudioI32>(b"sonara_audio_performance_mode\0")?;
            let sharing_mode = *library.get::<AudioI32>(b"sonara_audio_sharing_mode\0")?;
            let target_frames = *library.get::<AudioI32>(b"sonara_audio_target_frames\0")?;
            Ok(Self {
                _library: library,
                start,
                stop,
                write,
                rendered,
                underruns,
                dropped,
                silence_frames,
                rebuffer_events,
                reset_quality,
                disconnected,
                correction,
                buffered,
                sample_rate,
                channels,
                frames_per_burst,
                device_id,
                performance_mode,
                sharing_mode,
                target_frames,
            })
        }
    }

    fn start_primed(&self, target_buffer_frames: u32) -> Result<()> {
        let frames = i32::try_from(target_buffer_frames).context("target buffer is too large")?;
        let samples = vec![0i16; usize::try_from(frames)? * usize::from(CHANNELS)];
        let target = i32::try_from(target_buffer_frames).context("target buffer is too large")?;
        let result = unsafe { (self.start)(samples.as_ptr(), frames, target) };
        if result == 0 {
            Ok(())
        } else {
            bail!("Oboe failed to start with result {result}")
        }
    }

    fn write_pcm(&self, payload: &[u8], frames: u16) -> Result<()> {
        let samples = payload
            .chunks_exact(2)
            .map(|value| i16::from_le_bytes([value[0], value[1]]))
            .collect::<Vec<_>>();
        let accepted = unsafe { (self.write)(samples.as_ptr(), i32::from(frames)) };
        if accepted != i32::from(frames) {
            bail!("native render ring accepted {accepted} of {frames} frames")
        }
        Ok(())
    }

    fn update_metrics(&self) {
        let mut status = STATUS.lock().expect("status mutex poisoned");
        status.frames_rendered = unsafe { (self.rendered)() };
        status.output_underruns = unsafe { (self.underruns)() };
        status.output_dropped_frames = unsafe { (self.dropped)() };
        status.output_silence_frames = unsafe { (self.silence_frames)() };
        status.rebuffer_events = unsafe { (self.rebuffer_events)() };
        status.rate_correction_ppm = unsafe { (self.correction)() };
        status.buffered_frames = unsafe { (self.buffered)() };
        status.output_sample_rate = unsafe { (self.sample_rate)() };
        status.output_channels = unsafe { (self.channels)() };
        status.output_frames_per_burst = unsafe { (self.frames_per_burst)() };
        status.output_device_id = unsafe { (self.device_id)() };
        status.output_performance_mode = unsafe { (self.performance_mode)() };
        status.output_sharing_mode = unsafe { (self.sharing_mode)() };
        status.adaptive_buffer_ms =
            f64::from(unsafe { (self.target_frames)() }) * 1000.0 / f64::from(LOGICAL_SAMPLE_RATE);
    }
}

impl Drop for AudioApi {
    fn drop(&mut self) {
        unsafe { (self.stop)() };
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_sonara_sonara_SonaraService_nativeStart(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    invitation: JString<'_>,
) -> jboolean {
    if RUNNING.swap(true, Ordering::AcqRel) {
        return JNI_FALSE;
    }
    let encoded: String = match env.get_string(&invitation) {
        Ok(value) => value.into(),
        Err(error) => {
            RUNNING.store(false, Ordering::Release);
            set_error(format!("invalid invitation text: {error}"));
            return JNI_FALSE;
        }
    };
    STOP.store(false, Ordering::Release);
    set_status(ReceiverStatus {
        state: "connecting".into(),
        ..ReceiverStatus::default()
    });
    std::thread::spawn(move || {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        let result = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .context("creating Android receiver runtime")
            .and_then(|runtime| runtime.block_on(run_receiver(encoded.trim())));
        if let Err(error) = result {
            set_error(format!("{error:#}"));
        } else {
            STATUS.lock().expect("status mutex poisoned").state = "stopped".into();
        }
        RUNNING.store(false, Ordering::Release);
    });
    JNI_TRUE
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_sonara_sonara_SonaraService_nativeStop(
    _env: JNIEnv<'_>,
    _class: JClass<'_>,
) {
    STOP.store(true, Ordering::Release);
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_sonara_sonara_SonaraService_nativeStatus(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jstring {
    let json = serde_json::to_string(&*STATUS.lock().expect("status mutex poisoned"))
        .unwrap_or_else(|_| "{\"state\":\"error\"}".into());
    env.new_string(json)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

async fn run_receiver(encoded: &str) -> Result<()> {
    let invitation = Invitation::decode(encoded, unix_now()).context("decoding invitation")?;
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(
        invitation.host_certificate_der.clone(),
    ))?;
    let mut tls = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    tls.enable_early_data = false;
    let config = quinn::ClientConfig::new(std::sync::Arc::new(QuicClientConfig::try_from(tls)?));
    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(config);
    let connection = connect_to_any_endpoint(&endpoint, &invitation.endpoints).await?;
    let (mut send, mut recv) = connection.open_bi().await?;
    write_control(
        &mut send,
        &PairRequest {
            invitation_id: invitation.id,
            token: invitation.pairing_token().to_vec(),
            receiver_name: "sonara-android".into(),
        },
    )
    .await?;
    let response: PairResponse = read_control(&mut recv).await?;
    if !response.accepted {
        bail!("host rejected pairing: {}", response.message);
    }
    if response.sample_rate != LOGICAL_SAMPLE_RATE || response.channels != CHANNELS {
        bail!(
            "unsupported stream format: {} Hz, {} channels",
            response.sample_rate,
            response.channels
        );
    }

    let receiver_clock = Instant::now();
    for _ in 0..response.clock_probes {
        respond_to_clock(&mut send, &mut recv, receiver_clock).await?;
    }
    let ready: ClockControl = read_control(&mut recv).await?;
    let ClockControl::Ready {
        rate,
        offset_seconds,
        uncertainty_ms,
        start_host_time_ns,
        ..
    } = ready
    else {
        bail!("host did not finish clock synchronization");
    };
    {
        let mut status = STATUS.lock().expect("status mutex poisoned");
        status.state = "buffering".into();
        status.clock_uncertainty_ms = Some(uncertainty_ms);
        status.target_buffer_ms =
            f64::from(response.target_buffer_frames) * 1000.0 / f64::from(LOGICAL_SAMPLE_RATE);
        status.packet_duration_ms =
            f64::from(response.frame_count) * 1000.0 / f64::from(LOGICAL_SAMPLE_RATE);
        status.mode = response.mode.clone();
        status.profile = response.profile.clone();
    }
    write_control(&mut send, &ClockControl::PlaybackReady).await?;
    let receiver_start_seconds = rate * (start_host_time_ns as f64 / 1e9) + offset_seconds;
    let startup_lead_seconds =
        (f64::from(response.target_buffer_frames) / f64::from(LOGICAL_SAMPLE_RATE)).max(0.020);
    let remaining_seconds =
        receiver_start_seconds - receiver_clock.elapsed().as_secs_f64() - startup_lead_seconds;
    if remaining_seconds > 0.0 {
        tokio::time::sleep(Duration::from_secs_f64(remaining_seconds)).await;
    }
    let audio = AudioApi::load().context("loading Oboe adapter")?;
    audio.start_primed(response.target_buffer_frames)?;
    timeout(Duration::from_secs(2), async {
        while unsafe { (audio.rendered)() } == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .context("Android audio callback did not start in time")?;
    let priming_frames = u16::try_from(response.target_buffer_frames)
        .context("target buffer cannot be represented by the audio adapter")?;
    let priming_silence = vec![0u8; usize::from(priming_frames) * usize::from(CHANNELS) * 2];
    audio.write_pcm(&priming_silence, priming_frames)?;
    let control = tokio::spawn(async move {
        while !STOP.load(Ordering::Acquire) {
            if respond_to_clock(&mut send, &mut recv, receiver_clock)
                .await
                .is_err()
            {
                break;
            }
        }
    });

    let mut reorder = BTreeMap::<u32, AudioPacket>::new();
    let mut expected = None;
    let mut received_first_packet = false;
    let max_reorder_packets = usize::from(response.max_reorder_packets.max(1));
    let silence = vec![0; usize::from(response.frame_count) * usize::from(CHANNELS) * 2];
    loop {
        if STOP.load(Ordering::Acquire) {
            break;
        }
        let bytes = match timeout(Duration::from_millis(500), connection.read_datagram()).await {
            Ok(Ok(bytes)) => bytes,
            Ok(Err(quinn::ConnectionError::ApplicationClosed(close)))
                if close.error_code.into_inner() == 0 =>
            {
                break;
            }
            Ok(Err(error)) => {
                if STOP.load(Ordering::Acquire) {
                    break;
                }
                return Err(error.into());
            }
            Err(_) => {
                audio.update_metrics();
                continue;
            }
        };
        let packet = match AudioPacket::decode(&bytes) {
            Ok(packet)
                if packet.stream_id == STREAM_ID
                    && packet.epoch == response.epoch
                    && packet.frame_count == response.frame_count
                    && packet.kind == PCM16_KIND =>
            {
                packet
            }
            _ => {
                STATUS
                    .lock()
                    .expect("status mutex poisoned")
                    .invalid_packets += 1;
                continue;
            }
        };
        let next = *expected.get_or_insert(packet.sequence);
        if packet.sequence < next || reorder.contains_key(&packet.sequence) {
            STATUS
                .lock()
                .expect("status mutex poisoned")
                .redundant_packets += 1;
            continue;
        }
        reorder.insert(packet.sequence, packet);
        STATUS
            .lock()
            .expect("status mutex poisoned")
            .packets_received += 1;
        while let Some(packet) = reorder.remove(expected.as_ref().expect("sequence initialized")) {
            if !received_first_packet {
                received_first_packet = true;
                unsafe { (audio.reset_quality)() };
                STATUS.lock().expect("status mutex poisoned").state = "playing".into();
            }
            {
                let mut status = STATUS.lock().expect("status mutex poisoned");
                status.first_sequence.get_or_insert(packet.sequence);
                status.last_sequence = Some(packet.sequence);
                status
                    .first_source_time_ns
                    .get_or_insert(packet.source_time_ns);
                status.last_source_time_ns = Some(packet.source_time_ns);
            }
            audio.write_pcm(&packet.payload, packet.frame_count)?;
            *expected.as_mut().expect("sequence initialized") =
                expected.expect("sequence initialized").wrapping_add(1);
        }
        if reorder.len() >= max_reorder_packets {
            audio.write_pcm(&silence, response.frame_count)?;
            STATUS.lock().expect("status mutex poisoned").packets_lost += 1;
            *expected.as_mut().expect("sequence initialized") =
                expected.expect("sequence initialized").wrapping_add(1);
        }
        if unsafe { (audio.disconnected)() } != 0 {
            bail!("Android output route disconnected");
        }
        audio.update_metrics();
    }
    control.abort();
    connection.close(0u32.into(), b"receiver stopped");
    endpoint.wait_idle().await;
    Ok(())
}

async fn connect_to_any_endpoint(
    endpoint: &quinn::Endpoint,
    encoded_addresses: &[String],
) -> Result<quinn::Connection> {
    let mut attempts = tokio::task::JoinSet::new();
    let mut errors = Vec::new();
    for encoded in encoded_addresses {
        match encoded.parse::<SocketAddr>() {
            Ok(address) => {
                let endpoint = endpoint.clone();
                attempts.spawn(async move {
                    let connecting = endpoint.connect(address, "sonara.local")?;
                    let connection = timeout(Duration::from_secs(8), connecting)
                        .await
                        .with_context(|| format!("connection to {address} timed out"))??;
                    Ok::<_, anyhow::Error>((address, connection))
                });
            }
            Err(error) => errors.push(format!("{encoded}: {error}")),
        }
    }
    while let Some(result) = attempts.join_next().await {
        match result {
            Ok(Ok((_address, connection))) => {
                attempts.abort_all();
                return Ok(connection);
            }
            Ok(Err(error)) => errors.push(format!("{error:#}")),
            Err(error) if !error.is_cancelled() => errors.push(error.to_string()),
            Err(_) => {}
        }
    }
    bail!(
        "could not connect to any pinned Sonara endpoint: {}",
        errors.join("; ")
    )
}

async fn respond_to_clock(
    send: &mut quinn::SendStream,
    recv: &mut quinn::RecvStream,
    clock: Instant,
) -> Result<()> {
    let request: ClockControl = read_control(recv).await?;
    let ClockControl::Request { probe_id, t1_ns } = request else {
        bail!("unexpected clock message")
    };
    let t2_ns = clock.elapsed().as_nanos() as u64;
    let t3_ns = clock.elapsed().as_nanos() as u64;
    write_control(
        send,
        &ClockControl::Response {
            probe_id,
            t1_ns,
            t2_ns,
            t3_ns,
        },
    )
    .await
}

async fn write_control<T: Serialize>(send: &mut quinn::SendStream, value: &T) -> Result<()> {
    let payload = serde_json::to_vec(value)?;
    if payload.len() > CONTROL_LIMIT {
        bail!("control message exceeds 64 KiB");
    }
    send.write_all(&(payload.len() as u32).to_be_bytes())
        .await?;
    send.write_all(&payload).await?;
    Ok(())
}

async fn read_control<T: DeserializeOwned>(recv: &mut quinn::RecvStream) -> Result<T> {
    let mut length = [0; 4];
    recv.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    if length > CONTROL_LIMIT {
        bail!("control message exceeds 64 KiB");
    }
    let mut payload = vec![0; length];
    recv.read_exact(&mut payload).await?;
    serde_json::from_slice(&payload).context("decoding control message")
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn set_status(status: ReceiverStatus) {
    *STATUS.lock().expect("status mutex poisoned") = status;
}

fn set_error(message: String) {
    let mut status = STATUS.lock().expect("status mutex poisoned");
    status.state = "error".into();
    status.error = Some(message);
}
