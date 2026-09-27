use anyhow::{Context, Result, anyhow, bail};
use bytes::Bytes;
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use rustls::{
    RootCertStore,
    pki_types::{CertificateDer, PrivatePkcs8KeyDer},
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sonara_engine::{
    CHANNELS, LOGICAL_SAMPLE_RATE,
    invitation::{Invitation, certificate_fingerprint},
    packet::{AudioPacket, HEADER_LEN, PCM16_KIND},
    sync::{ClockEstimator, ClockExchange},
};
use std::{
    collections::{BTreeMap, VecDeque},
    f32::consts::TAU,
    io::{Seek, Write},
    net::SocketAddr,
    path::Path,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::{
    net::UdpSocket,
    time::{MissedTickBehavior, interval, sleep, timeout},
};
use uuid::Uuid;

const ALPN: &[u8] = b"sonara/1";
const CONTROL_LIMIT: usize = 64 * 1024;
const STREAM_ID: u32 = 1;
const DISCOVERY_PORT: u16 = 49_813;
const DISCOVERY_PROTOCOL: &str = "sonara-discovery/1";
const DISCOVERY_PROBE: &[u8] = b"SONARA_DISCOVER/1";

#[derive(Debug, Serialize)]
struct DiscoveryAnnouncement<'a> {
    protocol: &'static str,
    name: String,
    invitation: &'a str,
}

struct InvitationState {
    current: Invitation,
    previous: Option<Invitation>,
}

impl InvitationState {
    fn encoded(&self) -> String {
        self.current.encode()
    }

    fn authorizes(&self, request: &PairRequest, now: u64) -> bool {
        [
            &self.current,
            self.previous.as_ref().unwrap_or(&self.current),
        ]
        .into_iter()
        .any(|invitation| {
            request.invitation_id == invitation.id
                && invitation.token_matches(&request.token)
                && invitation.validate(now).is_ok()
        })
    }
}

#[derive(Clone, Copy)]
enum HostSource {
    Tone,
    #[cfg(windows)]
    Process(u32),
}

#[derive(Debug, Serialize, Deserialize)]
struct PairRequest {
    invitation_id: Uuid,
    token: Vec<u8>,
    receiver_name: String,
}

#[derive(Debug, Serialize, Deserialize)]
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

#[derive(Clone, Copy, Debug)]
pub struct HostTuning {
    pub frame_count: u16,
    pub target_buffer_frames: u32,
    pub max_reorder_packets: u16,
    pub clock_probes: u16,
    pub clock_probe_interval: Duration,
    pub mode: &'static str,
    pub profile: &'static str,
}

#[derive(Debug, Serialize, Deserialize)]
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

#[derive(Debug, Serialize)]
pub struct ReceiveReport {
    pub packets_received: u64,
    pub packets_lost: u64,
    pub invalid_packets: u64,
    pub redundant_packets: u64,
    pub frames_written: u64,
    pub duration_seconds: f64,
    pub rms: f64,
    pub clock_rate: f64,
    pub clock_offset_ms: f64,
    pub clock_uncertainty_ms: f64,
    pub clock_samples: usize,
    pub first_source_time_ns: Option<u64>,
    pub last_source_time_ns: Option<u64>,
    pub source_timestamp_regressions: u64,
    pub output: String,
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

async fn advertise_invitation(state: Arc<Mutex<InvitationState>>) -> Result<()> {
    let socket = UdpSocket::bind(("0.0.0.0", DISCOVERY_PORT))
        .await
        .context("binding LAN discovery socket")?;
    socket
        .set_broadcast(true)
        .context("enabling LAN discovery broadcast")?;
    let host_name = std::env::var("COMPUTERNAME")
        .ok()
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| "Sonara host".to_owned());
    let broadcast: SocketAddr = format!("255.255.255.255:{DISCOVERY_PORT}").parse()?;
    let mut ticker = interval(Duration::from_secs(1));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    // The socket can receive its own ~1 KiB broadcast announcement on Windows,
    // so the receive buffer must fit both probes and announcements.
    let mut probe = [0u8; 2048];
    loop {
        tokio::select! {
            _ = ticker.tick() => {
                let encoded = state.lock().expect("invitation mutex poisoned").encoded();
                let announcement = serde_json::to_vec(&DiscoveryAnnouncement {
                    protocol: DISCOVERY_PROTOCOL,
                    name: host_name.clone(),
                    invitation: &encoded,
                })?;
                let _ = socket.send_to(&announcement, broadcast).await;
            }
            received = socket.recv_from(&mut probe) => {
                let (length, peer) = received.context("receiving LAN discovery probe")?;
                if probe[..length] == DISCOVERY_PROBE[..] {
                    let encoded = state.lock().expect("invitation mutex poisoned").encoded();
                    let announcement = serde_json::to_vec(&DiscoveryAnnouncement {
                        protocol: DISCOVERY_PROTOCOL,
                        name: host_name.clone(),
                        invitation: &encoded,
                    })?;
                    let _ = socket.send_to(&announcement, peer).await;
                }
            }
        }
    }
}

fn make_server_config() -> Result<(quinn::ServerConfig, Vec<u8>, bool)> {
    let identity = crate::identity::load_or_create()?;
    let cert_bytes = identity.certificate_der;
    let cert_der = CertificateDer::from(cert_bytes.clone());
    let key_der = PrivatePkcs8KeyDer::from(identity.private_key_der);

    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert_der], key_der.into())?;
    tls.alpn_protocols = vec![ALPN.to_vec()];
    tls.max_early_data_size = 0;
    let mut config = quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    let transport = Arc::get_mut(&mut config.transport).context("exclusive transport config")?;
    transport.datagram_receive_buffer_size(Some(512 * 1024));
    // A receiver may pause its radio briefly while Android switches power or
    // scheduling states. Keep enough queued media for that transient without
    // evicting the delayed-redundancy copy.
    transport.datagram_send_buffer_size(512 * 1024);
    Ok((config, cert_bytes, identity.persistent))
}

fn make_client_config(cert_der: &[u8]) -> Result<quinn::ClientConfig> {
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(cert_der.to_vec()))?;
    let mut tls = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    tls.enable_early_data = false;
    Ok(quinn::ClientConfig::new(Arc::new(
        QuicClientConfig::try_from(tls)?,
    )))
}

pub async fn host_test_tone(
    listen: SocketAddr,
    advertise: Vec<SocketAddr>,
    duration: Duration,
    invitation_out: &Path,
    tuning: HostTuning,
) -> Result<()> {
    host_audio(
        listen,
        advertise,
        duration,
        invitation_out,
        HostSource::Tone,
        tuning,
    )
    .await
}

#[cfg(windows)]
pub async fn host_process(
    pid: u32,
    listen: SocketAddr,
    advertise: Vec<SocketAddr>,
    duration: Duration,
    invitation_out: &Path,
    tuning: HostTuning,
) -> Result<()> {
    host_audio(
        listen,
        advertise,
        duration,
        invitation_out,
        HostSource::Process(pid),
        tuning,
    )
    .await
}

async fn host_audio(
    listen: SocketAddr,
    advertise: Vec<SocketAddr>,
    duration: Duration,
    invitation_out: &Path,
    source: HostSource,
    tuning: HostTuning,
) -> Result<()> {
    let (config, cert_der, persistent_identity) = make_server_config()?;
    let endpoint = quinn::Endpoint::server(config, listen)?;
    let local_addr = endpoint.local_addr()?;
    let mut invitation_addrs = if advertise.is_empty() {
        vec![local_addr]
    } else {
        advertise
    };
    invitation_addrs.sort_unstable();
    invitation_addrs.dedup();
    if invitation_addrs
        .iter()
        .any(|address| address.ip().is_unspecified())
    {
        bail!("a wildcard listener requires --advertise with explicit eligible LAN addresses");
    }
    let invitation_endpoints: Vec<String> =
        invitation_addrs.iter().map(ToString::to_string).collect();
    let identity_fingerprint = certificate_fingerprint(&cert_der);
    let invitation = Invitation::issue(
        invitation_endpoints.clone(),
        identity_fingerprint.clone(),
        cert_der.clone(),
        unix_now(),
    );
    let encoded = invitation.encode();
    tokio::fs::write(invitation_out, &encoded)
        .await
        .with_context(|| format!("writing invitation to {}", invitation_out.display()))?;
    println!("INVITATION={encoded}");
    eprintln!(
        "Listening on {local_addr}; invitation written to {}; identity={}",
        invitation_out.display(),
        if persistent_identity {
            "os-protected"
        } else {
            "ephemeral"
        }
    );

    let invitations = Arc::new(Mutex::new(InvitationState {
        current: invitation,
        previous: None,
    }));
    let discovery_invitations = invitations.clone();
    let discovery_task = tokio::spawn(async move {
        if let Err(error) = advertise_invitation(discovery_invitations).await {
            eprintln!("LAN discovery unavailable: {error:#}");
        }
    });
    let rotation_invitations = invitations.clone();
    let rotation_path = invitation_out.to_path_buf();
    let rotation_task = tokio::spawn(async move {
        loop {
            sleep(Duration::from_secs(90)).await;
            let invitation = Invitation::issue(
                invitation_endpoints.clone(),
                identity_fingerprint.clone(),
                cert_der.clone(),
                unix_now(),
            );
            let encoded = invitation.encode();
            {
                let mut state = rotation_invitations
                    .lock()
                    .expect("invitation mutex poisoned");
                state.previous = Some(std::mem::replace(&mut state.current, invitation));
            }
            if let Err(error) = tokio::fs::write(&rotation_path, encoded).await {
                eprintln!("Could not rotate invitation file: {error}");
            }
        }
    });

    let host_clock = Arc::new(Instant::now());
    let session_start = Arc::new(Mutex::new(None::<u64>));
    let wait = duration;
    let first_connection = timeout(wait, async {
        loop {
            let incoming = endpoint
                .accept()
                .await
                .ok_or_else(|| anyhow!("QUIC endpoint closed"))?;
            match incoming.await {
                Ok(connection) => match prepare_receiver(
                    connection,
                    &invitations,
                    tuning,
                    host_clock.clone(),
                    session_start.clone(),
                )
                .await
                {
                    Ok(connection) => break Ok::<_, anyhow::Error>(connection),
                    Err(error) => eprintln!("Receiver rejected: {error:#}"),
                },
                Err(error) => eprintln!("QUIC handshake failed: {error}"),
            }
        }
    })
    .await
    .context("invitation expired before a receiver connected")??;
    let receivers = ReceiverSet::default();
    receivers.add(first_connection);
    let accept_endpoint = endpoint.clone();
    let accept_invitation = invitations.clone();
    let accept_receivers = receivers.clone();
    let accept_host_clock = host_clock.clone();
    let accept_session_start = session_start.clone();
    let accept_task = tokio::spawn(async move {
        while let Some(incoming) = accept_endpoint.accept().await {
            match incoming.await {
                Ok(connection) => {
                    match prepare_receiver(
                        connection,
                        &accept_invitation,
                        tuning,
                        accept_host_clock.clone(),
                        accept_session_start.clone(),
                    )
                    .await
                    {
                        Ok(connection) => {
                            accept_receivers.add(connection);
                            eprintln!(
                                "Receiver joined; {} listeners active",
                                accept_receivers.len()
                            );
                        }
                        Err(error) => eprintln!("Receiver rejected: {error:#}"),
                    }
                }
                Err(error) => eprintln!("QUIC handshake failed: {error}"),
            }
        }
    });
    let start_host_time_ns = (*session_start.lock().expect("session start mutex poisoned"))
        .context("first receiver did not schedule a stream start")?;
    let remaining_ns = start_host_time_ns.saturating_sub(host_clock.elapsed().as_nanos() as u64);
    if remaining_ns > 0 {
        sleep(Duration::from_nanos(remaining_ns)).await;
    }
    let frame_count = tuning.frame_count;
    let source_name = match source {
        HostSource::Tone => "generated 440 Hz tone".to_owned(),
        #[cfg(windows)]
        HostSource::Process(pid) => format!("WASAPI process tree {pid}"),
    };
    eprintln!(
        "Streaming {source_name} as PCM16 in {frame_count}-frame packets with a {:.1} ms {} / {} target",
        f64::from(tuning.target_buffer_frames) * 1000.0 / f64::from(LOGICAL_SAMPLE_RATE),
        tuning.mode,
        tuning.profile,
    );

    let (sent, expired) = match source {
        HostSource::Tone => stream_tone(receivers.clone(), frame_count, duration).await?,
        #[cfg(windows)]
        HostSource::Process(pid) => {
            stream_process(receivers.clone(), frame_count, pid, duration).await?
        }
    };
    eprintln!(
        "Stream complete: {sent} packets sent, {expired} expired under backpressure across {} receivers",
        receivers.len()
    );
    sleep(Duration::from_millis(100)).await;
    accept_task.abort();
    discovery_task.abort();
    rotation_task.abort();
    receivers.close_all();
    let _ = timeout(Duration::from_secs(2), endpoint.wait_idle()).await;
    Ok(())
}

async fn prepare_receiver(
    connection: quinn::Connection,
    invitations: &Arc<Mutex<InvitationState>>,
    tuning: HostTuning,
    host_clock: Arc<Instant>,
    session_start: Arc<Mutex<Option<u64>>>,
) -> Result<quinn::Connection> {
    let (mut send, mut recv) = timeout(Duration::from_secs(10), connection.accept_bi())
        .await
        .context("receiver did not authorize in time")??;
    let request: PairRequest = read_control(&mut recv)
        .await
        .context("reading pair request")?;
    let authorized = invitations
        .lock()
        .expect("invitation mutex poisoned")
        .authorizes(&request, unix_now());
    if !authorized {
        let response = PairResponse {
            accepted: false,
            message: "invalid or expired invitation".into(),
            sample_rate: LOGICAL_SAMPLE_RATE,
            channels: CHANNELS,
            frame_count: 0,
            epoch: 0,
            clock_probes: 0,
            target_buffer_frames: 0,
            max_reorder_packets: 0,
            mode: tuning.mode.into(),
            profile: tuning.profile.into(),
        };
        write_control(&mut send, &response).await?;
        send.finish()?;
        connection.close(1u32.into(), b"authorization failed");
        bail!("receiver authorization failed");
    }

    let maximum = connection
        .max_datagram_size()
        .context("peer does not support QUIC datagrams")?;
    let preferred_packet_size = HEADER_LEN + usize::from(tuning.frame_count) * 4;
    if maximum < preferred_packet_size {
        connection.close(2u32.into(), b"datagram size too small");
        bail!(
            "negotiated datagram limit {maximum} is below required packet size {preferred_packet_size}"
        );
    }

    let response = PairResponse {
        accepted: true,
        message: format!("authorized {}", request.receiver_name),
        sample_rate: LOGICAL_SAMPLE_RATE,
        channels: CHANNELS,
        frame_count: tuning.frame_count,
        epoch: 1,
        clock_probes: tuning.clock_probes,
        target_buffer_frames: tuning.target_buffer_frames,
        max_reorder_packets: tuning.max_reorder_packets,
        mode: tuning.mode.into(),
        profile: tuning.profile.into(),
    };
    write_control(&mut send, &response).await?;

    let mut estimator = ClockEstimator::default();
    for probe_id in 0..u64::from(response.clock_probes) {
        let t1_ns = host_clock.elapsed().as_nanos() as u64;
        write_control(&mut send, &ClockControl::Request { probe_id, t1_ns }).await?;
        let reply: ClockControl = read_control(&mut recv).await?;
        let t4 = host_clock.elapsed().as_secs_f64();
        let ClockControl::Response {
            probe_id: reply_id,
            t1_ns: reply_t1,
            t2_ns,
            t3_ns,
        } = reply
        else {
            bail!("receiver sent an unexpected clock message");
        };
        if reply_id != probe_id || reply_t1 != t1_ns {
            bail!("receiver sent a mismatched clock response");
        }
        estimator.observe(ClockExchange {
            t1: t1_ns as f64 / 1e9,
            t2: t2_ns as f64 / 1e9,
            t3: t3_ns as f64 / 1e9,
            t4,
        });
        sleep(tuning.clock_probe_interval).await;
    }
    let clock = estimator
        .model()
        .context("clock estimator received no valid exchanges")?;
    let start_host_time_ns = {
        let mut start = session_start.lock().expect("session start mutex poisoned");
        *start.get_or_insert_with(|| {
            (host_clock.elapsed() + Duration::from_secs(2)).as_nanos() as u64
        })
    };
    write_control(
        &mut send,
        &ClockControl::Ready {
            rate: clock.rate,
            offset_seconds: clock.offset_seconds,
            uncertainty_ms: clock.uncertainty_seconds * 1000.0,
            samples: clock.samples,
            start_host_time_ns,
        },
    )
    .await?;
    let playback_ready: ClockControl = timeout(Duration::from_secs(5), read_control(&mut recv))
        .await
        .context("receiver did not prepare audio output in time")??;
    if !matches!(playback_ready, ClockControl::PlaybackReady) {
        bail!("receiver sent an unexpected playback readiness message");
    }
    tokio::spawn(continue_host_clock(
        send,
        recv,
        host_clock,
        estimator,
        u64::from(response.clock_probes),
    ));
    eprintln!(
        "Receiver authorized; clock samples={}, uncertainty={:.3} ms",
        clock.samples,
        clock.uncertainty_seconds * 1000.0,
    );
    Ok(connection)
}

#[derive(Clone, Default)]
struct ReceiverSet(Arc<Mutex<Vec<quinn::Connection>>>);

impl ReceiverSet {
    fn add(&self, connection: quinn::Connection) {
        self.0
            .lock()
            .expect("receiver set mutex poisoned")
            .push(connection);
    }

    fn len(&self) -> usize {
        self.0.lock().expect("receiver set mutex poisoned").len()
    }

    fn send_packet(&self, encoded: Bytes) -> u64 {
        let mut expired = 0u64;
        self.0
            .lock()
            .expect("receiver set mutex poisoned")
            .retain(|connection| {
                if connection.datagram_send_buffer_space() < encoded.len() {
                    expired += 1;
                }
                connection.send_datagram(encoded.clone()).is_ok()
            });
        expired
    }

    fn close_all(&self) {
        for connection in self
            .0
            .lock()
            .expect("receiver set mutex poisoned")
            .drain(..)
        {
            connection.close(0u32.into(), b"stream complete");
        }
    }
}

struct MediaSender {
    receivers: ReceiverSet,
    frame_count: u16,
    started: Instant,
    sequence: u32,
    first_frame: u64,
    sent: u64,
    expired: u64,
}

impl MediaSender {
    fn new(receivers: ReceiverSet, frame_count: u16) -> Self {
        Self {
            receivers,
            frame_count,
            started: Instant::now(),
            sequence: 0,
            first_frame: 0,
            sent: 0,
            expired: 0,
        }
    }

    fn send(&mut self, payload: Vec<u8>, source_time_ns: Option<u64>) -> Result<()> {
        let packet = AudioPacket {
            version: 1,
            kind: PCM16_KIND,
            frame_count: self.frame_count,
            stream_id: STREAM_ID,
            epoch: 1,
            sequence: self.sequence,
            first_frame: self.first_frame,
            source_time_ns: source_time_ns
                .unwrap_or_else(|| self.started.elapsed().as_nanos() as u64),
            payload,
        };
        let encoded = Bytes::from(packet.encode()?);
        self.expired += self.receivers.send_packet(encoded);
        self.sent += 1;
        self.sequence = self.sequence.wrapping_add(1);
        self.first_frame += u64::from(self.frame_count);
        Ok(())
    }

    async fn send_paced(
        &mut self,
        payload: Vec<u8>,
        source_time_ns: Option<u64>,
        next_deadline: &mut Option<Instant>,
        packet_period: Duration,
    ) -> Result<()> {
        let scheduled = *next_deadline;
        if let Some(deadline) = scheduled {
            tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)).await;
        }
        self.send(payload, source_time_ns)?;
        let now = Instant::now();
        *next_deadline = Some(
            scheduled
                .map(|deadline| deadline + packet_period)
                .filter(|deadline| *deadline > now)
                .unwrap_or(now),
        );
        Ok(())
    }

    fn totals(self) -> (u64, u64) {
        (self.sent, self.expired)
    }
}

async fn stream_tone(
    receivers: ReceiverSet,
    frame_count: u16,
    duration: Duration,
) -> Result<(u64, u64)> {
    let packet_period = Duration::from_secs_f64(frame_count as f64 / LOGICAL_SAMPLE_RATE as f64);
    let mut ticker = interval(packet_period);
    // Catch-up bursts create a large queue followed by starvation on remote
    // renderers. Delay the cadence after a late wake-up to preserve spacing.
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut media = MediaSender::new(receivers, frame_count);
    let mut phase = 0f32;
    let phase_step = 440.0 * TAU / LOGICAL_SAMPLE_RATE as f32;
    let total_packets = (duration.as_secs_f64() / packet_period.as_secs_f64()).ceil() as u64;
    for _ in 0..total_packets {
        ticker.tick().await;
        let mut payload = Vec::with_capacity(frame_count as usize * 4);
        for _ in 0..frame_count {
            let sample = (phase.sin() * i16::MAX as f32 * 0.2) as i16;
            phase = (phase + phase_step) % TAU;
            payload.extend_from_slice(&sample.to_le_bytes());
            payload.extend_from_slice(&sample.to_le_bytes());
        }
        media.send(payload, None)?;
    }
    Ok(media.totals())
}

#[cfg(windows)]
async fn stream_process(
    receivers: ReceiverSet,
    frame_count: u16,
    pid: u32,
    duration: Duration,
) -> Result<(u64, u64)> {
    let (sender, mut receiver) = tokio::sync::broadcast::channel(16);
    let capture = tokio::task::spawn_blocking(move || {
        crate::windows_capture::capture_process_stream(pid, duration, sender)
    });
    let packet_bytes = frame_count as usize * usize::from(CHANNELS) * 2;
    let mut pending = VecDeque::with_capacity(packet_bytes * 3);
    let mut media = MediaSender::new(receivers, frame_count);
    let mut capture_expired = 0u64;
    let mut first_qpc = None;
    let mut next_source_time_ns = 0u64;
    let packet_period =
        Duration::from_secs_f64(f64::from(frame_count) / f64::from(LOGICAL_SAMPLE_RATE));
    let mut next_send_deadline = None;
    let packet_duration_ns =
        u64::from(frame_count) * 1_000_000_000 / u64::from(LOGICAL_SAMPLE_RATE);
    loop {
        match receiver.recv().await {
            Ok(block) => {
                let qpc_origin = *first_qpc.get_or_insert(block.qpc_position);
                if pending.is_empty() {
                    next_source_time_ns = block.qpc_position.saturating_sub(qpc_origin) * 100;
                }
                if block.discontinuity {
                    capture_expired += 1;
                }
                pending.extend(block.pcm);
                while pending.len() >= packet_bytes {
                    let payload = pending.drain(..packet_bytes).collect();
                    media
                        .send_paced(
                            payload,
                            Some(next_source_time_ns),
                            &mut next_send_deadline,
                            packet_period,
                        )
                        .await?;
                    next_source_time_ns = next_source_time_ns.saturating_add(packet_duration_ns);
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(count)) => {
                capture_expired = capture_expired.saturating_add(count);
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    }
    let (captured_frames, capture_discontinuities) =
        capture.await.context("WASAPI capture worker panicked")??;
    if !pending.is_empty() {
        pending.resize(packet_bytes, 0);
        media
            .send_paced(
                pending.into(),
                Some(next_source_time_ns),
                &mut next_send_deadline,
                packet_period,
            )
            .await?;
    }
    let (sent, network_expired) = media.totals();
    eprintln!(
        "WASAPI complete: {captured_frames} frames, {capture_discontinuities} device discontinuities, {capture_expired} expired capture blocks"
    );
    Ok((sent, network_expired.saturating_add(capture_expired)))
}

pub async fn receive(invitation: Invitation, output: &Path) -> Result<ReceiveReport> {
    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(make_client_config(&invitation.host_certificate_der)?);
    let connection = connect_to_any_endpoint(&endpoint, &invitation.endpoints).await?;
    let (mut send, mut recv) = connection.open_bi().await?;
    let request = PairRequest {
        invitation_id: invitation.id,
        token: invitation.pairing_token().to_vec(),
        receiver_name: format!("sonara-cli-{}", std::env::consts::OS),
    };
    write_control(&mut send, &request).await?;
    let response: PairResponse = read_control(&mut recv)
        .await
        .context("invalid host response")?;
    if !response.accepted {
        bail!("host rejected pairing: {}", response.message);
    }

    let receiver_clock = Instant::now();
    for _ in 0..response.clock_probes {
        let request: ClockControl = read_control(&mut recv).await?;
        let t2_ns = receiver_clock.elapsed().as_nanos() as u64;
        let ClockControl::Request { probe_id, t1_ns } = request else {
            bail!("host sent an unexpected clock message");
        };
        let t3_ns = receiver_clock.elapsed().as_nanos() as u64;
        write_control(
            &mut send,
            &ClockControl::Response {
                probe_id,
                t1_ns,
                t2_ns,
                t3_ns,
            },
        )
        .await?;
    }
    let clock: ClockControl = read_control(&mut recv).await?;
    let ClockControl::Ready {
        rate: clock_rate,
        offset_seconds,
        uncertainty_ms,
        samples: clock_samples,
        start_host_time_ns: _,
    } = clock
    else {
        bail!("host did not finish clock synchronization");
    };
    write_control(&mut send, &ClockControl::PlaybackReady).await?;
    let clock_task = tokio::spawn(continue_receiver_clock(send, recv, receiver_clock));

    let spec = hound::WavSpec {
        channels: response.channels,
        sample_rate: response.sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(output, spec)
        .with_context(|| format!("creating {}", output.display()))?;
    let started = Instant::now();
    let mut received = 0u64;
    let mut lost = 0u64;
    let mut invalid = 0u64;
    let mut redundant = 0u64;
    let mut frames = 0u64;
    let mut expected_sequence: Option<u32> = None;
    let mut reorder = BTreeMap::<u32, AudioPacket>::new();
    let mut square_sum = 0f64;
    let mut sample_count = 0u64;
    let mut first_source_time_ns = None;
    let mut last_source_time_ns = None;
    let mut source_timestamp_regressions = 0u64;
    loop {
        let bytes = match timeout(Duration::from_secs(5), connection.read_datagram()).await {
            Ok(Ok(bytes)) => bytes,
            Ok(Err(_)) => break,
            Err(_) => bail!("audio stream stalled for five seconds"),
        };
        let packet = match AudioPacket::decode(&bytes) {
            Ok(packet) => packet,
            Err(_) => {
                invalid += 1;
                continue;
            }
        };
        if packet.stream_id != STREAM_ID
            || packet.epoch != response.epoch
            || packet.frame_count != response.frame_count
        {
            invalid += 1;
            continue;
        }
        if expected_sequence.is_none() {
            expected_sequence = Some(packet.sequence);
        }
        if packet.sequence < expected_sequence.unwrap() || reorder.contains_key(&packet.sequence) {
            redundant += 1;
            continue;
        }
        reorder.insert(packet.sequence, packet);
        received += 1;
        while let Some(packet) = reorder.remove(&expected_sequence.unwrap()) {
            observe_source_timestamp(
                packet.source_time_ns,
                &mut first_source_time_ns,
                &mut last_source_time_ns,
                &mut source_timestamp_regressions,
            );
            let (samples, energy) = write_payload(&mut writer, &packet.payload)?;
            sample_count += samples;
            square_sum += energy;
            frames += u64::from(packet.frame_count);
            expected_sequence = Some(expected_sequence.unwrap().wrapping_add(1));
        }
        if reorder.len() >= 20 {
            // The missing packet has passed the bounded reorder horizon.
            write_silence(&mut writer, response.frame_count, response.channels)?;
            frames += u64::from(response.frame_count);
            sample_count += u64::from(response.frame_count) * u64::from(response.channels);
            lost += 1;
            expected_sequence = Some(expected_sequence.unwrap().wrapping_add(1));
        }
    }
    while let Some((&highest, _)) = reorder.last_key_value() {
        let expected = expected_sequence.unwrap();
        if let Some(packet) = reorder.remove(&expected) {
            observe_source_timestamp(
                packet.source_time_ns,
                &mut first_source_time_ns,
                &mut last_source_time_ns,
                &mut source_timestamp_regressions,
            );
            let (samples, energy) = write_payload(&mut writer, &packet.payload)?;
            sample_count += samples;
            square_sum += energy;
            frames += u64::from(packet.frame_count);
        } else if expected <= highest {
            write_silence(&mut writer, response.frame_count, response.channels)?;
            frames += u64::from(response.frame_count);
            sample_count += u64::from(response.frame_count) * u64::from(response.channels);
            lost += 1;
        }
        expected_sequence = Some(expected.wrapping_add(1));
    }
    writer.finalize()?;
    clock_task.abort();
    endpoint.wait_idle().await;
    Ok(ReceiveReport {
        packets_received: received,
        packets_lost: lost,
        invalid_packets: invalid,
        redundant_packets: redundant,
        frames_written: frames,
        duration_seconds: started.elapsed().as_secs_f64(),
        rms: if sample_count == 0 {
            0.0
        } else {
            (square_sum / sample_count as f64).sqrt()
        },
        clock_rate,
        clock_offset_ms: offset_seconds * 1000.0,
        clock_uncertainty_ms: uncertainty_ms,
        clock_samples,
        first_source_time_ns,
        last_source_time_ns,
        source_timestamp_regressions,
        output: output.display().to_string(),
    })
}

async fn connect_to_any_endpoint(
    endpoint: &quinn::Endpoint,
    encoded_addresses: &[String],
) -> Result<quinn::Connection> {
    let mut attempts = tokio::task::JoinSet::new();
    let mut parse_errors = Vec::new();
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
            Err(error) => parse_errors.push(format!("{encoded}: {error}")),
        }
    }
    let mut errors = parse_errors;
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

fn observe_source_timestamp(
    value: u64,
    first: &mut Option<u64>,
    last: &mut Option<u64>,
    regressions: &mut u64,
) {
    first.get_or_insert(value);
    if last.is_some_and(|previous| value < previous) {
        *regressions += 1;
    }
    *last = Some(value);
}

async fn continue_host_clock(
    mut send: quinn::SendStream,
    mut recv: quinn::RecvStream,
    host_clock: Arc<Instant>,
    mut estimator: ClockEstimator,
    mut probe_id: u64,
) {
    let mut ticker = interval(Duration::from_millis(500));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        ticker.tick().await;
        let t1_ns = host_clock.elapsed().as_nanos() as u64;
        if write_control(&mut send, &ClockControl::Request { probe_id, t1_ns })
            .await
            .is_err()
        {
            break;
        }
        let Ok(ClockControl::Response {
            probe_id: reply_id,
            t1_ns: reply_t1,
            t2_ns,
            t3_ns,
        }) = read_control(&mut recv).await
        else {
            break;
        };
        if reply_id == probe_id && reply_t1 == t1_ns {
            estimator.observe(ClockExchange {
                t1: t1_ns as f64 / 1e9,
                t2: t2_ns as f64 / 1e9,
                t3: t3_ns as f64 / 1e9,
                t4: host_clock.elapsed().as_secs_f64(),
            });
        }
        probe_id = probe_id.wrapping_add(1);
    }
}

async fn continue_receiver_clock(
    mut send: quinn::SendStream,
    mut recv: quinn::RecvStream,
    receiver_clock: Instant,
) {
    while let Ok(ClockControl::Request { probe_id, t1_ns }) = read_control(&mut recv).await {
        let t2_ns = receiver_clock.elapsed().as_nanos() as u64;
        let t3_ns = receiver_clock.elapsed().as_nanos() as u64;
        if write_control(
            &mut send,
            &ClockControl::Response {
                probe_id,
                t1_ns,
                t2_ns,
                t3_ns,
            },
        )
        .await
        .is_err()
        {
            break;
        }
    }
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
    let mut length = [0u8; 4];
    recv.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    if length > CONTROL_LIMIT {
        bail!("control frame exceeds 64 KiB");
    }
    let mut payload = vec![0u8; length];
    recv.read_exact(&mut payload).await?;
    serde_json::from_slice(&payload).context("decoding control message")
}

fn write_payload<W: Write + Seek>(
    writer: &mut hound::WavWriter<W>,
    payload: &[u8],
) -> Result<(u64, f64)> {
    let mut samples = 0u64;
    let mut energy = 0.0;
    for bytes in payload.chunks_exact(2) {
        let sample = i16::from_le_bytes([bytes[0], bytes[1]]);
        writer.write_sample(sample)?;
        let normalized = f64::from(sample) / f64::from(i16::MAX);
        energy += normalized * normalized;
        samples += 1;
    }
    Ok((samples, energy))
}

fn write_silence<W: Write + Seek>(
    writer: &mut hound::WavWriter<W>,
    frames: u16,
    channels: u16,
) -> Result<()> {
    for _ in 0..u32::from(frames) * u32::from(channels) {
        writer.write_sample(0i16)?;
    }
    Ok(())
}
