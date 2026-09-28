# Sonara

Sonara sends audio from a Windows PC or Apple Silicon Mac to nearby Android devices so they can play it at nearly the same time. It is designed for devices on the same local network. The project is open source under the MIT License.

Network and device timing vary, and low software buffer settings do not guarantee a particular speaker-to-speaker delay. See [Known limitations](#known-limitations) before relying on it for precise synchronization.

## What Sonara does

- Captures audio from a selected Windows or macOS application or from all system audio.
- Lets Android devices find a running Sonara desktop host on the local network and connect to it.
- Streams audio over a direct, authenticated connection. The host does not send audio through a Sonara cloud service.
- Synchronizes device clocks and schedules playback using audio timestamps.
- Keeps Android playback active when the screen is off, using Android's media playback controls and foreground playback service.
- Shows connected receivers on the host and the selected output route and connection state on Android.
- Offers adjustable buffer profiles to balance responsiveness and recovery from network jitter.

Sonara does not require an account. It does not record microphone input, store or upload streamed audio, or send telemetry.

## How a session works

1. Start a Sonara session on Windows or macOS and choose **System audio** or a running application.
2. Sonara advertises the host on the local network. Nearby Android devices listen for these announcements and can also probe the network to find a host.
3. Select the host on Android. The devices establish an authenticated connection using a short-lived invitation and the host's identity.
4. The host streams timestamped audio. Android uses clock measurements and its current system media output route to schedule playback.
5. Stop the receiver on Android or stop the host session to end playback and streaming.

Automatic discovery generally requires both devices to be on the same Wi-Fi, Ethernet, or tethered local network, with local-network traffic allowed. If discovery is unavailable, Android can connect using a copied invitation. Do not share an invitation with anyone you do not intend to connect.

## Use the desktop and Android apps

### Windows

Use the portable package from a GitHub release, or build the app as described below. Keep `sonara.exe`, `sonara_engine.exe`, the `data` directory, and the accompanying runtime files together. Start `sonara.exe`, select **System audio** or an application, and choose **Start session**. Sonara chooses an active local-network address automatically.

Closing the app window minimizes Sonara to the notification area while a session is active. Open the tray icon to restore the window, or use its menu to exit.

### macOS

Sonara supports Apple Silicon Macs running macOS 14.2 or newer. Download the arm64 DMG from GitHub Releases, drag Sonara to Applications, and open it. This release is ad hoc signed but has no Apple Developer ID signature or notarization. If macOS blocks its first launch, try opening it, then use **System Settings → Privacy & Security → Open Anyway**. The first capture asks for **System Audio Recording** permission; allow it for Sonara. Select **System audio** or an application and start a session. Closing the window keeps Sonara in the menu bar; use **Open Sonara** or **Quit Sonara** there. Capture permission may need to be granted again after an unsigned update.

### Android

Install the signed APK from a GitHub release, then open **Session** or **Devices** and choose a nearby Sonara host. Android may ask to allow notifications or to install apps from the browser or file manager you used. Keep the host and phone on the same local network for discovery and streaming.

Playback follows Android's current media output route. To change between the phone speaker, headphones, or another supported route, use Android's media output panel.

## Build from source

### Prerequisites

- Git
- Flutter stable and dependencies for the target platform
- Rust stable and Cargo
- For Android: Android SDK/NDK, Rust targets `aarch64-linux-android` and `x86_64-linux-android`, and `cargo-ndk`
- For macOS: an Apple Silicon Mac, Xcode, and the Rust `aarch64-apple-darwin` target

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

On macOS, run `flutter run -d macos` from `apps/sonara`. The Xcode build also builds and bundles `sonara_engine`. Use `python3 build.py --target macos --mode production` from the repository root to create the arm64 DMG. For Android development on this Mac, run `flutter doctor --android-licenses`, install `cargo-ndk`, and use `python3 build.py --target android --mode debug`. Android production packaging requires the approved release keystore and `key.properties` in `apps/sonara/android`.

The interactive `build.py` menu also works from Python IDLE: choose **macOS → Production**. The finished DMG and checksum are in `dist/`.

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
- Desktop capture can send selected process audio or system output, but Sonara cannot currently delay unmanaged local speaker playback to guarantee acoustic alignment with the receiving phone.
- Android uses the platform's current output route; Sonara does not select or control every device-specific audio route.
- Discovery depends on local-network permissions and router behavior. Guest Wi-Fi, client isolation, VPNs, firewalls, or hotspot settings may block it. Manual invitation entry is available as a fallback.
- Timing measurements and network synchronization are not the same as measuring sound waves from physical speakers. A shared-clock recording is needed to measure acoustic skew.
- On macOS, protected audio and applications without a Core Audio process may not be capturable. The macOS release supports Apple Silicon only.

## Contributing

Bug reports and focused pull requests are welcome. Include the host OS and Android versions, connection method, selected output route, and privacy-scrubbed diagnostics when relevant. Do not include invitations, private keys, keystores, passwords, or recordings containing private audio.

## License

Sonara is distributed under the [MIT License](LICENSE).
