# Building Sonara

This document explains how to build, package, sign, and distribute Sonara.

It is intended for contributors and maintainers working on local development builds, production packages, GitHub Releases, Android signing, and optional Google Play distribution.

> [!IMPORTANT]
> Never commit keystores, passwords, service-account JSON files, private certificates, signing credentials, or other secrets to Git.

---

# Supported platforms

Sonara currently targets:

| Platform | Development | Production packaging |
| --- | --- | --- |
| Windows | Supported | Supported |
| Android | Supported | Supported |
| macOS 14.2+ on Apple Silicon | Supported | Ad hoc signed GitHub DMG |

Current Android application ID:

```text
com.htdevs.sonara
```

The Android package is registered for Android developer verification.

Production Android builds must use an approved release signing certificate associated with this package.

---

# Repository build entry points

Sonara provides two primary build interfaces.

## Interactive build menu

From the repository root:

```powershell
python .\build.py
```

The build menu allows selecting:

- Android
- Windows
- macOS on Apple Silicon
- All supported platforms
- Debug
- Production

The menu remains open after a build and prints the paths of generated outputs.

This is the recommended entry point for normal local packaging.

## Direct production packaging

For a non-interactive production package build:

```powershell
.\tools\packaging\build-release.ps1 -Platform All
```

Individual platforms can also be selected when supported by the script.

Production artifacts are written to:

```text
dist/
```

SHA-256 checksum sidecars are generated alongside release artifacts.

---

# Prerequisites

The exact tools required depend on the platform being built.

## Common requirements

Install:

- Git
- Python 3
- Flutter stable
- Rust stable
- Cargo

Verify the installations:

```powershell
git --version
python --version
flutter --version
rustc --version
cargo --version
```

Run:

```powershell
flutter doctor
```

Resolve any errors relevant to the platforms you intend to build.

---

# Rust setup

Install Rust using the standard Rust toolchain installer.

Confirm:

```powershell
rustc --version
cargo --version
```

Update Rust when necessary:

```powershell
rustup update
```

If the project specifies a particular toolchain, use that toolchain instead of overriding it globally.

---

# Flutter setup

Install the current stable Flutter channel.

Check the active channel:

```powershell
flutter channel
```

Switch to stable if necessary:

```powershell
flutter channel stable
flutter upgrade
```

Verify:

```powershell
flutter doctor
```

Install project dependencies from the relevant Flutter application directory:

```powershell
flutter pub get
```

Do not manually edit generated Flutter dependency files unless the project specifically requires it.

---

# Android requirements

Android builds require:

- Android SDK
- Android platform tools
- Android build tools
- Android NDK
- Java/JDK compatible with the current Flutter/Gradle setup
- `cargo-ndk`

Install `cargo-ndk`:

```powershell
cargo install cargo-ndk
```

Verify:

```powershell
cargo ndk --version
```

Run:

```powershell
flutter doctor
```

The Android toolchain section should report no blocking issues.

---

# Windows requirements

Windows builds require a Windows development environment compatible with Flutter desktop.

Install the Visual Studio components requested by:

```powershell
flutter doctor
```

This generally includes the C++ desktop development toolchain.

For production installer generation, Sonara can additionally use:

```text
Inno Setup 6
```

Inno Setup is optional for development builds but may be required for generating the final Windows installer.

---

# Optional Python dependency for icon generation

Sonara's generated desktop icon assets are checked into the repository.

You therefore do not need Pillow for a normal build.

If regenerating the rounded desktop icon assets, install Pillow:

```powershell
python -m pip install Pillow
```

---

# Clone and prepare the repository

Clone Sonara:

```powershell
git clone <repository-url>
cd Sonara
```

Fetch dependencies required by the project.

For Flutter components:

```powershell
flutter pub get
```

For Rust components, Cargo resolves dependencies automatically during the build.

Before working on a release, make sure the repository is in the expected state:

```powershell
git status
```

Production releases should normally be built from a clean, reviewed commit.

---

# Development builds

Development builds are intended for testing and debugging.

Run:

```powershell
python .\build.py
```

Choose the desired platform and:

```text
Debug
```

Debug builds may:

- include development instrumentation
- use development configuration
- skip production packaging
- produce unsigned or development-signed Android builds
- have lower performance than optimized release builds

Do not distribute debug builds as official Sonara releases.

---

# Production builds

Run:

```powershell
python .\build.py
```

Then select:

```text
Production
```

Alternatively:

```powershell
.\tools\packaging\build-release.ps1 -Platform All
```

Production packaging should:

- build optimized binaries
- generate distributable platform packages
- use production Android signing where configured
- generate SHA-256 checksums
- place final artifacts in `dist/`

Always inspect the output before publishing it.

---

# Windows production packaging

A Sonara Windows release can include:

- Windows installer
- Portable ZIP archive
- SHA-256 checksum for each artifact

The exact filenames may include the Sonara version.

Example release layout:

```text
dist/
├── Sonara-Setup-x.y.z.exe
├── Sonara-Setup-x.y.z.exe.sha256
├── Sonara-x.y.z-windows-portable.zip
└── Sonara-x.y.z-windows-portable.zip.sha256
```

Exact filenames are controlled by the packaging scripts and may change.

---

# Android production packaging

Official Android release packages use:

```text
com.htdevs.sonara
```

The GitHub release process currently distributes a signed APK.

Google Play distribution uses an Android App Bundle when enabled:

```text
.aab
```

The APK and AAB serve different distribution workflows.

## GitHub Releases

GitHub can distribute the signed APK directly.

Users download and install the APK themselves.

No Play Store testing or production track is required for this distribution method.

## Google Play

Google Play normally receives an Android App Bundle:

```powershell
flutter build appbundle --release
```

Google Play then generates the APKs delivered to devices.

---

# Android signing

Production Android releases must be cryptographically signed.

The private signing keystore must never be committed to the repository.

Sonara's package:

```text
com.htdevs.sonara
```

is registered for Android developer verification.

Use a release signing key whose SHA-256 certificate fingerprint is registered for that package.

---

# Inspecting an Android keystore

Use `keytool`:

```powershell
keytool -list -v -keystore path\to\release-key.jks -alias your-key-alias
```

Locate the certificate's:

```text
SHA256
```

fingerprint.

Compare it with the certificate fingerprints registered for:

```text
com.htdevs.sonara
```

in Play Console.

Certificate fingerprints are public information.

The following are private and must never be published:

- keystore files
- private keys
- passwords
- signing credentials

---

# Unapproved local signing keys

A local keystore available during initial release setup did not match the signing certificates registered for:

```text
com.htdevs.sonara
```

Do not use an unregistered key for official Sonara distribution unless it is intentionally registered and verified first.

This protects users from receiving builds that cannot participate in the expected application update chain.

---

# Back up the Android release key

Keep the official Android signing key backed up securely.

Losing the key used to sign GitHub-distributed APKs may prevent future releases from updating existing installations.

Recommended protections include:

- encrypted offline backup
- secure password manager for signing credentials
- access restricted to maintainers
- at least one independent backup location

Do not store the only copy in GitHub Actions.

---

# GitHub Actions Android signing

The GitHub release workflow expects the Android release signing material to be configured using GitHub Actions secrets.

Configure:

| Secret | Purpose |
| --- | --- |
| `SONARA_ANDROID_KEYSTORE_BASE64` | Base64 representation of the release keystore |
| `SONARA_ANDROID_STORE_PASSWORD` | Keystore password |
| `SONARA_ANDROID_KEY_ALIAS` | Alias of the signing key |
| `SONARA_ANDROID_KEY_PASSWORD` | Password for the private signing key |

Configure this GitHub Actions repository variable:

| Variable | Purpose |
| --- | --- |
| `SONARA_ANDROID_REGISTERED_CERT_SHA256` | Expected SHA-256 certificate fingerprint |

Colons in the fingerprint may be included or omitted according to the workflow normalization logic.

---

# Encoding the Android keystore

A keystore can be converted to Base64 using PowerShell:

```powershell
[Convert]::ToBase64String(
    [IO.File]::ReadAllBytes('path\to\release-key.jks')
)
```

> [!WARNING]
> The resulting Base64 value contains the complete keystore data.
>
> Treat it exactly like the original keystore file.
>
> Do not publish it, paste it into documentation, upload it to an issue, include it in logs, or share it through chat.

Store the resulting value directly as:

```text
SONARA_ANDROID_KEYSTORE_BASE64
```

in GitHub Actions secrets.

---

# Certificate verification in CI

Before producing an Android release, the GitHub Actions workflow verifies that the certificate contained in the provided keystore matches:

```text
SONARA_ANDROID_REGISTERED_CERT_SHA256
```

This prevents an accidentally supplied signing key from silently producing an official Sonara release.

If the fingerprints do not match, the Android release job should fail before publishing the APK.

This check verifies the configured certificate identity.

It does not replace proper protection of the private signing key.

---

# GitHub Release workflow

The release workflow is located at:

```text
.github/workflows/release.yml
```

It is responsible for building production release artifacts.

The workflow runs when a GitHub Release is published.

A manual workflow dispatch can also operate on an existing release tag when supported by the workflow.

---

# GitHub Release artifacts

Current production release targets include:

## Windows

- Setup installer `.exe` (uploaded as its own release asset)
- Portable `.zip`
- A SHA-256 checksum alongside each file

## Android

- Signed installer `.apk` (uploaded as its own release asset)
- SHA-256 checksum

## macOS

The macOS lane builds an Apple Silicon `.app` with its bundled Rust engine, signs the app and helper ad hoc, and packages a `.dmg` with a SHA-256 checksum. It does not use a Developer ID certificate or notarization. Users must approve first launch in **System Settings → Privacy & Security → Open Anyway** and grant System Audio Recording permission when prompted.

---

# Creating a GitHub release

A typical release process is:

1. Update the Sonara version.
2. Commit the release changes.
3. Merge or otherwise finalize the release commit.
4. Create the matching Git tag.
5. Push the tag.
6. Create a GitHub Release using that tag.
7. Publish the release.
8. Allow the release workflow to build the artifacts.
9. Verify every artifact and checksum.
10. Test installation on representative devices.

Exact versioning and tagging conventions should remain consistent across releases.

Example tag:

```text
v1.0.0
```

---

# Manual release workflow

The GitHub Actions workflow supports manual dispatch for release maintenance where configured.

This can be useful for:

- rebuilding assets
- attaching missing release artifacts
- replacing invalid release artifacts
- testing the production build workflow

Use the exact existing release tag when operating on an existing GitHub Release.

Do not create conflicting artifacts under the same version without understanding the update implications.

---

# SHA-256 checksums

Official artifacts include SHA-256 sidecar files.

A checksum allows users and maintainers to verify that a downloaded artifact matches the generated release file.

Example:

```text
Sonara-x.y.z.apk
Sonara-x.y.z.apk.sha256
```

On Windows, a file can be checked with:

```powershell
Get-FileHash .\Sonara-x.y.z.apk -Algorithm SHA256
```

Compare the resulting hash with the value in the corresponding `.sha256` file.

---

# GitHub-only Android distribution

Sonara can distribute Android APKs exclusively through GitHub Releases.

Google Play is not required.

For this model:

1. Build the production APK.
2. Sign it using the official Sonara release key.
3. Verify its signing certificate.
4. Generate its checksum.
5. Publish the APK and checksum on GitHub Releases.

Users install the APK manually.

Android may show installation warnings or confirmation prompts for applications installed outside Google Play.

This is expected.

---

# Play internal testing

Google Play internal testing can be used when a small known group should receive Sonara through Play Store infrastructure.

Typical setup:

1. Create the Play application using:

```text
com.htdevs.sonara
```

2. Configure Play App Signing.
3. Build an Android App Bundle.
4. Upload the `.aab`.
5. Create an internal testing release.
6. Add testers.
7. Share the tester enrollment link.

Internal testing does not make Sonara publicly available through the Play Store production listing.

---

# Other Google Play tracks

Google Play provides multiple release channels.

## Internal testing

Suitable for:

- maintainers
- trusted testers
- small test groups
- rapid pre-release validation

## Closed testing

Suitable for:

- invited beta groups
- larger controlled testing
- staged community testing

## Open testing

Suitable for:

- public beta programs
- users who intentionally opt into testing

## Production

Suitable for:

- public Play Store distribution

Production Play distribution is optional and is not required for GitHub APK releases.

---

# Play App Signing

When distributing through Google Play, understand the difference between:

- app signing key
- upload key

With Play App Signing, Google protects the app signing key used for the APKs ultimately delivered to users.

The developer normally signs uploaded bundles with an upload key.

These keys can be different.

---

# GitHub APK and Play Store update compatibility

Signing identity matters when users switch between distribution channels.

An application installed from GitHub can normally only be updated by an APK that Android considers signed by a compatible certificate.

Google Play may use a different app signing certificate from the certificate used for GitHub APKs.

If seamless switching between GitHub-installed and Play-installed copies is important, design the signing arrangement before widespread distribution.

Do not assume a GitHub APK and a Play-delivered application will automatically share the same signing identity.

---

# Automated Google Play uploads

The current GitHub release workflow does not need Google credentials to publish the GitHub APK.

Google Play automation can be added independently.

A typical automated Play configuration requires:

1. A Google Cloud project.
2. Google Play Developer API enabled.
3. A service account.
4. Minimum required Play Console permissions.
5. A GitHub Actions service-account secret.
6. An `.aab` build step.
7. A Play upload step.

Suggested secret:

```text
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON
```

Suggested repository variable:

```text
SONARA_PLAY_TRACK
```

Example:

```text
SONARA_PLAY_TRACK=internal
```

Never use a personal Google account password in CI.

---

# Building an Android App Bundle locally

For Play distribution:

```powershell
flutter build appbundle --release
```

The exact output path depends on the Flutter project structure.

A typical Flutter result resembles:

```text
build/app/outputs/bundle/release/app-release.aab
```

Sonara's packaging system may copy or rename this artifact when Play automation is introduced.

---

# Building an Android APK locally

For direct APK testing:

```powershell
flutter build apk --release
```

The standard Flutter output is typically similar to:

```text
build/app/outputs/flutter-apk/app-release.apk
```

For official Sonara distribution, prefer the repository packaging scripts so signing, verification, naming, and checksum generation remain consistent.

---

# Verify APK signing

An APK should be checked before release.

Depending on the installed Android SDK tools, use:

```powershell
apksigner verify --verbose --print-certs path\to\sonara.apk
```

Confirm:

- signature verification succeeds
- package identity is expected
- signing certificate SHA-256 matches the approved Sonara certificate

Never publish an APK whose signing identity has not been verified.

---

# Clean builds

If a build behaves unexpectedly, clean generated Flutter state:

```powershell
flutter clean
flutter pub get
```

For Rust:

```powershell
cargo clean
```

Only clean caches when necessary. Rebuilding all native dependencies can substantially increase build time.

---

# Dependency updates

Do not upgrade dependencies immediately before a production release unless the changes are intentional and tested.

For Flutter:

```powershell
flutter pub outdated
```

For Rust:

```powershell
cargo update
```

Review dependency changes instead of automatically accepting large upgrades.

Production releases should come from a reproducible, reviewed dependency state.

---

# Troubleshooting

## `flutter doctor` reports Android problems

Run:

```powershell
flutter doctor -v
```

Check:

- Android SDK installation
- SDK licenses
- Java installation
- Android Studio or command-line tools
- NDK installation

Accept SDK licenses if appropriate:

```powershell
flutter doctor --android-licenses
```

---

## `cargo ndk` is missing

Install it:

```powershell
cargo install cargo-ndk
```

Then verify:

```powershell
cargo ndk --version
```

---

## Android signing fails

Verify:

- the keystore is valid
- the alias exists
- the store password is correct
- the key password is correct
- the certificate fingerprint matches the expected release certificate

Inspect it with:

```powershell
keytool -list -v -keystore path\to\release-key.jks -alias your-key-alias
```

---

## GitHub Actions reports certificate mismatch

The certificate inside:

```text
SONARA_ANDROID_KEYSTORE_BASE64
```

does not match:

```text
SONARA_ANDROID_REGISTERED_CERT_SHA256
```

Determine which one is incorrect before proceeding.

Do not bypass the check merely to make the workflow succeed.

---

## Windows installer is not generated

Check whether Inno Setup 6 is installed and available to the packaging script.

The portable build may still succeed even when installer generation is unavailable.

---

## Python icon generation fails

If intentionally regenerating icon assets, install Pillow:

```powershell
python -m pip install Pillow
```

Normal builds should use the committed generated assets and should not require Pillow.

---

## Build output appears stale

Clean the relevant platform and rebuild.

Flutter:

```powershell
flutter clean
flutter pub get
```

Then rerun:

```powershell
python .\build.py
```

---

# macOS support

On an Apple Silicon Mac with Xcode, Flutter, and Rust installed, run `python3 build.py --target macos --mode debug` for a development app or `python3 build.py --target macos --mode production` for a DMG. The Mac Xcode build compiles and bundles the Rust engine automatically. `python3 build.py --target all --mode debug` builds macOS and Android on a Mac; Windows and Android on Windows.

You can also open `build.py` in Python IDLE and choose **2. macOS → 1. Production**. The launcher locates Flutter when IDLE starts with a minimal `PATH`. If your Flutter SDK is in a custom location, set `SONARA_FLUTTER_BIN` to the full path of its `bin/flutter` executable before launching the builder. The production DMG and its `.sha256` file appear in `dist/`.

For Android builds on a Mac, accept Android SDK licenses with `flutter doctor --android-licenses`, install `cargo-ndk`, and install both Android Rust targets. Mac Android production packaging requires the existing approved `release-key.jks` and `key.properties`; it never generates a new signing key.

The Mac release supports macOS 14.2+ and arm64 only. System audio capture uses Core Audio process taps and asks for System Audio Recording permission. Unsigned updates may prompt again for capture permission. If Developer ID signing and notarization are added later, retest first launch, update behavior, and capture permission identity.

Current Flutter stable releases can crash while generating macOS AOT code for unused experimental windowing structs ([Flutter issue #191575](https://github.com/flutter/flutter/issues/191575)). `build-macos.sh` temporarily disables that experimental SDK feature for its Release build and restores the Flutter SDK afterward. Remove the workaround when Flutter fixes the compiler issue.

---

# Release security rules

Maintainers should follow these rules for every production release:

1. Never commit signing credentials.
2. Never commit an Android keystore.
3. Never publish keystore Base64 data.
4. Never commit service-account JSON.
5. Never use a personal Google password in CI.
6. Verify Android signing certificates before release.
7. Use GitHub Actions secrets for confidential values.
8. Keep release signing keys securely backed up.
9. Verify generated checksums.
10. Test release artifacts before announcing them.
11. Review the commit and tag being released.
12. Keep GitHub and Play signing strategies documented.

---

# Files that must never be committed

At minimum, do not commit files such as:

```text
*.jks
*.keystore
*.p12
*.pfx
*.pem
service-account.json
google-play-service-account.json
```

Also avoid committing:

```text
.env
.env.production
.env.local
```

when they contain credentials.

The repository `.gitignore` should provide additional protection, but `.gitignore` is not a substitute for carefully checking staged files.

Before committing:

```powershell
git status
git diff --cached
```

---

# Secret exposure response

If a signing key, password, service-account credential, or similar secret is accidentally committed:

1. Treat it as compromised.
2. Remove access to the exposed credential where possible.
3. Rotate or replace it.
4. Update CI secrets.
5. Investigate whether the secret reached a remote repository.
6. Do not rely only on deleting the latest Git commit.

Git history may retain sensitive material even after the visible file is removed.

Signing-key rotation may require additional platform-specific procedures.

---

# Recommended release checklist

Before publishing:

- [ ] Version is correct
- [ ] Release notes are prepared
- [ ] Repository working tree is clean
- [ ] Intended commit has been reviewed
- [ ] Windows production build succeeds
- [ ] Android production build succeeds
- [ ] Android application ID is `com.htdevs.sonara`
- [ ] Android release certificate is approved
- [ ] APK signature verification succeeds
- [ ] Checksums are generated
- [ ] Windows installer launches correctly
- [ ] Windows portable build launches correctly
- [ ] Android APK installs correctly
- [ ] Basic audio/session functionality has been tested
- [ ] Release tag is correct
- [ ] No credentials are present in artifacts
- [ ] GitHub Release assets are complete

For Play distribution:

- [ ] `.aab` is generated
- [ ] Correct Play application is selected
- [ ] Correct Play track is selected
- [ ] Version code is valid
- [ ] Upload key is correct
- [ ] Play release details have been reviewed

---

# Recommended release flow

For a normal Sonara GitHub release:

```text
Development
    ↓
Tests
    ↓
Release version update
    ↓
Production local build
    ↓
Signing verification
    ↓
Commit
    ↓
Tag
    ↓
GitHub Release
    ↓
GitHub Actions production builds
    ↓
Artifact verification
    ↓
Publish / announce
```

For Google Play:

```text
GitHub release process
    ↓
Build signed AAB
    ↓
Upload to selected Play track
    ↓
Play processing
    ↓
Tester / production distribution
```

---

# Distribution summary

Sonara can be distributed without Google Play.

For open-source GitHub distribution:

```text
Signed APK
+
SHA-256 checksum
+
GitHub Release
```

is sufficient.

Google Play is optional and primarily provides:

- managed installation
- automatic updates
- testing tracks
- Play Store discovery
- centralized Play distribution

Regardless of distribution channel, preserve Sonara's signing identity carefully.

---

# Maintainer notes

The Android signing key is part of Sonara's long-term application identity.

Before changing:

- application ID
- release signing certificate
- Play App Signing configuration
- GitHub APK signing strategy
- update mechanism

consider the effect on users who already have Sonara installed.

A release that cannot update an existing installation effectively creates a separate installation lineage even when the visible application name remains the same.

Keep release infrastructure changes deliberate, reviewed, and documented.
