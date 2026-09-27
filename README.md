# Sonara

Sonara is a local-first Windows and Android audio synchronization project. It has no account, cloud relay, telemetry, or implicit recording.

This repository contains an executable POC: a standalone Windows host, portable Rust logic, a developer CLI, direct Windows WASAPI process-tree capture, authenticated QUIC/PCM streaming, deterministic timing simulation, protocol definitions, and a Flutter app with an Android foreground receiver backed by Rust/JNI and Oboe. The Windows app discovers live applications and LAN interfaces dynamically, owns the native host process, and continues in the notification area when its window is closed.

## Run

### Windows desktop app

Build the complete desktop bundle once, then launch the window by double-clicking `sonara.exe` (or with the final command below):

```powershell
cd apps\sonara
flutter build windows --release
.\build\windows\x64\runner\Release\sonara.exe
```

Choose a running application in the dynamic source list and click **Start session**. Android listeners on the same Wi-Fi, Ethernet, or tethered LAN discover the PC automatically and connect with one tap; copy/paste remains only as a fallback. The desktop app selects an active LAN address itself—there is no PID or `YOUR_PC_IP` placeholder to replace. Closing the window hides it to the notification area while the host remains active; double-click the Sonara tray icon to restore it, or right-click it and choose **Exit**. The release directory is the portable app: keep its DLL, `data` folder, and internal `sonara_engine.exe` beside `sonara.exe`.

### Developer CLI

```powershell
$env:PATH = "C:\Users\USER\.cargo\bin;$env:PATH"
cargo run -p sonara -- dev simulate --scenario tests/scenarios/good-lan.toml
cargo run -p sonara -- diagnostics export --output run.json
# Terminal 1: writes a certificate-pinned, two-minute invitation
cargo run -p sonara -- host --test-tone --listen 127.0.0.1:49812 --duration 5
# Or capture one running Windows process tree in real time
cargo run -p sonara -- host --pid 1234 --listen 127.0.0.1:49812 --duration 5
# Terminal 2: saves authenticated PCM packets as a WAV file
cargo run -p sonara -- receive --invitation-file sonara-invitation.txt --output received.wav
```

For another LAN device, listen on `0.0.0.0:49812` and pass the explicitly selected eligible interface as `--advertise 192.168.1.10:49812`. Sonara does not guess or silently select a cellular route.

On Android, open **Session** or **Devices** and select the PC under **Nearby Sonara hosts**. The listener sends an active LAN probe and also receives one-second host beacons; stale sessions disappear after six seconds. Receiving is owned by a media-playback foreground service and continues with the screen off. Device name, ABI, selected output route, native sample rate, channel count, frames per burst, buffer occupancy, and timing metrics are discovered at runtime; no phone model is selected in product code. An emulator reaches the same protocol and Oboe callback path, but it is not evidence of physical acoustic timing.

Low Delay + Balanced is the default measured profile. It starts with a 20 ms software render queue and can adapt up to 60 ms when the network or platform genuinely underruns. Ultra Low adapts from 10–30 ms and Stable from 50–150 ms in Low Delay mode (up to 240 ms in Synchronized mode). A recovery pauses consumption once, refills at a slightly larger target, and resumes; after ten stable seconds the target steps back down. Stale audio remains bounded instead of allowing delay to grow indefinitely. These are software queue targets, not guaranteed capture-to-speaker latency; Android hardware, Wi-Fi scheduling, and the selected output route add time. Sonara also cannot delay an unmanaged PC speaker, so exact acoustic synchronization with audio still playing directly on the PC requires a future Sonara-controlled local output path.

The CLI also exposes `devices` and `sources`. `host --test-tone`, `host --pid`, and `receive` exercise the real QUIC datagram path. Low-latency pairing performs 12 initial clock exchanges at 100 Hz and continues probing at 2 Hz while streaming. The process path requests 48 kHz PCM16 stereo directly from WASAPI, carries capture QPC timestamps into packet source time, joins Windows' Pro Audio scheduling class, and uses a bounded 16-block capture ring that expires old audio instead of accumulating latency. Packets split from a WASAPI block are paced on absolute media deadlines instead of being emitted as a burst. Windows requests 1 ms timer resolution and test-tone pacing delays after missed ticks rather than sending catch-up bursts.

To measure real speaker-to-speaker skew, record both outputs as separate channels using one shared-clock recorder, then run:

```powershell
cargo run -p sonara -- dev measure-sync --input .\two-speakers.wav --reference-channel 0 --target-channel 1
```

The JSON result reports signed offset, normalized correlation, peak-to-sidelobe ratio, and a conservative confidence label. Clock synchronization alone is never presented as proof of acoustic alignment.

For a local capture-only diagnostic, run `cargo run -p sonara -- dev capture --pid 1234 --duration 5 --output captured.wav`. Silence is reported as an observation, not proof that an application forbids capture.

On Windows, the host certificate is stable across runs and its private key is encrypted for the current user with DPAPI under `%LOCALAPPDATA%\Sonara\identity`. Set `SONARA_IDENTITY_DIR` only for isolated development or test identities.

## Verify

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
pwsh -File tests/integration/quic-loopback.ps1
# Windows machine with an active audio service:
pwsh -File tests/integration/windows-process-loopback.ps1
# With any booted Android device/emulator (auto-discovered emulator by default):
pwsh -File tests/integration/android-emulator-loopback.ps1
# Add -ScreenOff only when explicitly testing background playback.
# Extended lifecycle/soak invocation:
pwsh -File tests/integration/android-emulator-loopback.ps1 -NoBuild -DurationSeconds 1800
Push-Location apps/sonara
flutter analyze
flutter test
flutter build windows --debug
flutter build apk --debug
Pop-Location
```

Android builds require Rust targets `aarch64-linux-android` and `x86_64-linux-android`, plus `cargo-ndk`. Gradle invokes the Rust build automatically and packages both ABIs.

## Package releases

Run the end-to-end packager from the repository root:

```powershell
.\tools\packaging\build-release.ps1 -Platform All
```

It builds the Windows release bundle, portable ZIP, unsigned per-user installer, and a developer-signed Android release APK under `dist`. On its first Android run it creates a dedicated local release key and credentials under `apps/sonara/android`; both are ignored by Git. Back them up securely—losing the key prevents in-place updates to installed APKs. SHA-256 sidecar files are generated for every distributable.

See [PLAN.md](PLAN.md) and [architecture status](docs/architecture/README.md). Licensed under MIT.
