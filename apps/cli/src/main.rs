use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand, ValueEnum};
use sonara_engine::{
    diagnostics::Diagnostics,
    invitation::Invitation,
    simulation::{self, Scenario},
};
use std::{
    fs,
    net::SocketAddr,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

mod identity;
mod network;
#[cfg(windows)]
mod windows_capture;

#[derive(Parser)]
#[command(
    name = "sonara",
    version,
    about = "Sonara local-network audio developer CLI"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Devices,
    Sources,
    Pair {
        #[command(subcommand)]
        command: PairCommand,
    },
    Host {
        #[arg(long, required_unless_present = "test_tone")]
        pid: Option<u32>,
        /// Stream a generated 440 Hz tone through the real QUIC/PCM path.
        #[arg(long, conflicts_with = "pid")]
        test_tone: bool,
        #[arg(long, default_value = "127.0.0.1:49812")]
        listen: SocketAddr,
        /// Address placed in the invitation for a wildcard listener.
        #[arg(long)]
        advertise: Option<SocketAddr>,
        #[arg(long, default_value_t = 5.0)]
        duration: f64,
        #[arg(long, default_value = "sonara-invitation.txt")]
        invitation_out: PathBuf,
        #[arg(long, value_enum, default_value = "synchronized")]
        mode: Mode,
        #[arg(long, value_enum, default_value = "balanced")]
        profile: Profile,
    },
    Receive {
        #[arg(
            long,
            conflicts_with = "invitation_file",
            required_unless_present = "invitation_file"
        )]
        invitation: Option<String>,
        #[arg(
            long,
            conflicts_with = "invitation",
            required_unless_present = "invitation"
        )]
        invitation_file: Option<PathBuf>,
        #[arg(long, default_value = "received.wav")]
        output: PathBuf,
    },
    Dev {
        #[command(subcommand)]
        command: DevCommand,
    },
    Diagnostics {
        #[command(subcommand)]
        command: DiagnosticsCommand,
    },
}
#[derive(Subcommand)]
enum PairCommand {
    Invite {
        #[arg(long, default_value = "127.0.0.1:49812")]
        endpoint: String,
    },
}
#[derive(Subcommand)]
enum DevCommand {
    Simulate {
        #[arg(long)]
        scenario: PathBuf,
        #[arg(long)]
        json: bool,
    },
    /// Capture one Windows process tree through WASAPI into a diagnostic WAV.
    Capture {
        #[arg(long)]
        pid: u32,
        #[arg(long, default_value_t = 5.0)]
        duration: f64,
        #[arg(long, default_value = "captured.wav")]
        output: PathBuf,
    },
}
#[derive(Subcommand)]
enum DiagnosticsCommand {
    Export {
        #[arg(long)]
        output: PathBuf,
    },
}
#[derive(Clone, ValueEnum, Debug)]
enum Mode {
    Synchronized,
    LowDelay,
}
#[derive(Clone, ValueEnum, Debug)]
enum Profile {
    UltraLow,
    Balanced,
    Stable,
}

fn host_tuning(mode: &Mode, profile: &Profile) -> network::HostTuning {
    let low_delay = matches!(mode, Mode::LowDelay);
    match profile {
        Profile::UltraLow => network::HostTuning {
            frame_count: 240,
            target_buffer_frames: 480,
            max_reorder_packets: 2,
            clock_probes: 12,
            clock_probe_interval: Duration::from_millis(10),
            mode: if low_delay {
                "low_delay"
            } else {
                "synchronized"
            },
            profile: "ultra_low",
        },
        Profile::Balanced => network::HostTuning {
            frame_count: 240,
            target_buffer_frames: if low_delay { 960 } else { 1_440 },
            max_reorder_packets: if low_delay { 3 } else { 4 },
            clock_probes: 12,
            clock_probe_interval: Duration::from_millis(10),
            mode: if low_delay {
                "low_delay"
            } else {
                "synchronized"
            },
            profile: "balanced",
        },
        Profile::Stable => network::HostTuning {
            frame_count: 240,
            target_buffer_frames: if low_delay { 2_400 } else { 3_840 },
            max_reorder_packets: 8,
            clock_probes: 20,
            clock_probe_interval: Duration::from_millis(20),
            mode: if low_delay {
                "low_delay"
            } else {
                "synchronized"
            },
            profile: "stable",
        },
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(windows)]
struct TimerResolution;

#[cfg(windows)]
impl TimerResolution {
    fn request() -> Option<Self> {
        let result = unsafe { windows::Win32::Media::timeBeginPeriod(1) };
        (result == 0).then_some(Self)
    }
}

#[cfg(windows)]
impl Drop for TimerResolution {
    fn drop(&mut self) {
        unsafe {
            windows::Win32::Media::timeEndPeriod(1);
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    #[cfg(windows)]
    let _timer_resolution = TimerResolution::request();
    // Dependencies may enable more than one rustls backend. Select one
    // explicitly so startup is deterministic on Windows and Android hosts.
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    match Cli::parse().command {
        Command::Devices => println!(
            "No active native outputs found by this foundation build. Run the Flutter app for platform route inventory."
        ),
        Command::Sources => list_sources(),
        Command::Pair {
            command: PairCommand::Invite { endpoint },
        } => {
            bail!(
                "an invitation must be bound to a live TLS identity at {endpoint}; run `sonara host --test-tone --listen {endpoint}`"
            );
        }
        Command::Receive {
            invitation,
            invitation_file,
            output,
        } => {
            let encoded = match (invitation, invitation_file) {
                (Some(value), None) => value,
                (None, Some(path)) => fs::read_to_string(&path)
                    .with_context(|| format!("reading {}", path.display()))?,
                _ => unreachable!("clap enforces exactly one invitation source"),
            };
            let invite = Invitation::decode(encoded.trim(), now())?;
            let report = network::receive(invite, &output).await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Command::Host {
            pid,
            test_tone,
            listen,
            advertise,
            duration,
            invitation_out,
            mode,
            profile,
        } => {
            if !(0.1..=86400.0).contains(&duration) {
                bail!("duration must be between 0.1 and 86400 seconds");
            }
            eprintln!("mode={mode:?}, profile={profile:?}");
            let tuning = host_tuning(&mode, &profile);
            if test_tone {
                network::host_test_tone(
                    listen,
                    advertise,
                    Duration::from_secs_f64(duration),
                    &invitation_out,
                    tuning,
                )
                .await?;
            } else {
                let pid = pid.expect("clap requires PID when test tone is disabled");
                if !process_exists(pid) {
                    bail!("process {pid} does not exist");
                }
                #[cfg(windows)]
                network::host_process(
                    pid,
                    listen,
                    advertise,
                    Duration::from_secs_f64(duration),
                    &invitation_out,
                    tuning,
                )
                .await?;
                #[cfg(not(windows))]
                bail!("process-loopback hosting is available on Windows only");
            }
        }
        Command::Dev {
            command: DevCommand::Simulate { scenario, json },
        } => {
            let source = fs::read_to_string(&scenario)
                .with_context(|| format!("reading {}", scenario.display()))?;
            let config: Scenario = toml::from_str(&source).context("parsing scenario TOML")?;
            let report = simulation::run(&config);
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!(
                    "Scenario: {}\nProbes: {}/{}\nEstimated drift: {:.2} ppm\nOffset error: {:.3} ms\nUncertainty: {:.3} ms\nTiming: {}",
                    report.scenario,
                    report.probes_received,
                    report.probes_sent,
                    report.estimated_drift_ppm,
                    report.offset_error_ms,
                    report.uncertainty_ms,
                    report.timing_quality
                );
            }
        }
        Command::Dev {
            command:
                DevCommand::Capture {
                    pid,
                    duration,
                    output,
                },
        } => {
            if !(0.1..=60.0).contains(&duration) {
                bail!("capture duration must be between 0.1 and 60 seconds");
            }
            #[cfg(windows)]
            {
                if !process_exists(pid) {
                    bail!("process {pid} does not exist");
                }
                let capture_output = output.clone();
                let report = tokio::task::spawn_blocking(move || {
                    windows_capture::capture_process_to_wav(
                        pid,
                        Duration::from_secs_f64(duration),
                        &capture_output,
                    )
                })
                .await
                .context("capture worker panicked")??;
                println!("{}", serde_json::to_string_pretty(&report)?);
            }
            #[cfg(not(windows))]
            bail!("process-loopback capture is available on Windows only");
        }
        Command::Diagnostics {
            command: DiagnosticsCommand::Export { output },
        } => {
            let d = Diagnostics::scrubbed_example(now());
            fs::write(&output, serde_json::to_vec_pretty(&d)?)
                .with_context(|| format!("writing {}", output.display()))?;
            println!("Wrote privacy-scrubbed diagnostics to {}", output.display());
        }
    }
    Ok(())
}

#[cfg(windows)]
fn process_exists(pid: u32) -> bool {
    std::process::Command::new("powershell").args(["-NoProfile","-Command",&format!("if (Get-Process -Id {pid} -ErrorAction SilentlyContinue) {{ exit 0 }} else {{ exit 1 }}")]).status().is_ok_and(|s|s.success())
}
#[cfg(not(windows))]
fn process_exists(pid: u32) -> bool {
    std::path::Path::new(&format!("/proc/{pid}")).exists()
}
fn list_sources() {
    #[cfg(windows)]
    {
        let _=std::process::Command::new("powershell").args(["-NoProfile","-Command","Get-Process | Where-Object {$_.MainWindowTitle} | Sort-Object ProcessName | Select-Object -First 25 Id,ProcessName,MainWindowTitle | Format-Table -AutoSize"]).status();
    }
    #[cfg(not(windows))]
    println!("Source enumeration is currently implemented for Windows only.");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ultra_low_negotiates_ten_millisecond_buffer_and_small_packets() {
        let tuning = host_tuning(&Mode::LowDelay, &Profile::UltraLow);
        assert_eq!(tuning.frame_count, 240);
        assert_eq!(tuning.target_buffer_frames, 480);
        assert_eq!(tuning.max_reorder_packets, 2);
        assert_eq!(tuning.mode, "low_delay");
        assert_eq!(tuning.profile, "ultra_low");
    }
}
