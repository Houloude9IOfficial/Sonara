# Sonara

Sonara sends audio from a Windows PC to nearby Android devices so they can play it at nearly the same time. It is designed for devices on the same local network. The project is open source under the MIT License.

Network and device timing vary, and low software buffer settings do not guarantee a particular speaker-to-speaker delay. See [Known limitations](#known-limitations) before relying on it for precise synchronization.

## What Sonara does

- Captures audio from a selected Windows application or from all system audio.
- Lets Android devices find a running Sonara PC on the local network and connect to it.
- Streams audio over a direct, authenticated connection. The PC does not send audio through a Sonara cloud service.
- Synchronizes device clocks and schedules playback using audio timestamps.
- Keeps Android playback active when the screen is off, using Android's media playback controls and foreground playback service.
- Shows connected receivers on the PC and the selected output route and connection state on Android.
- Offers adjustable buffer profiles to balance responsiveness and recovery from network jitter.

Sonara does not require an account. It does not record microphone input, store or upload streamed audio, or send telemetry.

## How a session works

1. Start a Sonara session on the Windows PC and choose **System audio** or a running application.
2. Sonara advertises the host on the local network. Nearby Android devices listen for these announcements and can also probe the network to find a host.
3. Select the PC on Android. The devices establish an authenticated connection using a short-lived invitation and the host's identity.
4. The PC streams timestamped audio. Android uses clock measurements and its current system media output route to schedule playback.
5. Stop the receiver on Android or stop the session on Windows to end playback and streaming.

Automatic discovery generally requires both devices to be on the same Wi-Fi, Ethernet, or tethered local network, with local-network traffic allowed. If discovery is unavailable, Android can connect using a copied invitation. Do not share an invitation with anyone you do not intend to connect.

## Use the Windows and Android apps

### Windows

Use the portable package from a GitHub release, or build the app as described below. Keep `sonara.exe`, `sonara_engine.exe`, the `data` directory, and the accompanying runtime files together. Start `sonara.exe`, select **System audio** or an application, and choose **Start session**. Sonara chooses an active local-network address automatically.

Closing the app window minimizes Sonara to the notification area while a session is active. Open the tray icon to restore the window, or use its menu to exit.

### Android

Install the signed APK from a GitHub release, then open **Session** or **Devices** and choose a nearby Sonara PC. Android may ask to allow notifications or to install apps from the browser or file manager you used. Keep the PC and phone on the same local network for discovery and streaming.

Playback follows Android's current media output route. To change between the phone speaker, headphones, or another supported route, use Android's media output panel.

## Build from source

### Prerequisites

- Git
- Flutter stable and its Windows and Android build dependencies
- Rust stable and Cargo
- For Android: Android SDK/NDK, Rust targets `aarch64-linux-android` and `x86_64-linux-android`, and `cargo-ndk`

Fetch Flutter packages and build the app:

```powershell
Push-Location apps\sonara
flutter pub get
flutter run -d windows
# Or create a Windows release build:
flutter build windows --release
# Or create an Android debug APK:
flutter build apk --debug
Pop-Location
```

Production packaging, Android signing, GitHub release automation, and optional Play Store distribution are documented separately in [apps/build.md](apps/build.md) for project maintainers.

## Development and tests

Run the checks from the repository root:

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
Push-Location apps\sonara
flutter analyze
flutter test
Pop-Location
```

The `tests/integration/` directory contains scripts for local streaming, Windows audio capture, and Android receiver checks. Some checks require a Windows audio session or a connected Android device/emulator. Emulator success does not measure real speaker-to-speaker timing.

## Known limitations

- Sonara is in active development. Wi-Fi contention, Android device scheduling, and audio hardware can add delay or cause buffering.
- Buffer profiles control Sonara's software queue. They do not promise a specific end-to-end or acoustic latency.
- Windows capture can send selected process audio or system output, but Sonara cannot currently delay unmanaged PC speaker playback to guarantee acoustic alignment with the receiving phone.
- Android uses the platform's current output route; Sonara does not select or control every device-specific audio route.
- Discovery depends on local-network permissions and router behavior. Guest Wi-Fi, client isolation, VPNs, firewalls, or hotspot settings may block it. Manual invitation entry is available as a fallback.
- Timing measurements and network synchronization are not the same as measuring sound waves from physical speakers. A shared-clock recording is needed to measure acoustic skew.
- macOS support is not available yet.

## Contributing

Bug reports and focused pull requests are welcome. Include the Windows and Android versions, connection method, selected output route, and privacy-scrubbed diagnostics when relevant. Do not include invitations, private keys, keystores, passwords, or recordings containing private audio.

## License

Sonara is distributed under the [MIT License](LICENSE).
