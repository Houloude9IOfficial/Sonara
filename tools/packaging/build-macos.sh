#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
app_dir="$root_dir/apps/sonara"
dist_dir="$root_dir/dist"
version="$(sed -nE 's/^version: *([^+ ]+).*/\1/p' "$app_dir/pubspec.yaml" | head -1)"
test -n "$version"
test "$(uname -m)" = arm64
python_bin="${SONARA_PYTHON:-python3}"

cd "$app_dir"
flutter config --enable-macos-arm64-only
flutter pub get

# Flutter 3.44-3.47 can retain an unused experimental windowing FFI struct in
# macOS AOT builds (flutter/flutter#191575). Disable that feature only while
# compiling, then restore the installed SDK even when the build fails.
flutter_bin="$("$python_bin" -c 'import os, shutil; print(os.path.realpath(shutil.which("flutter")))')"
flutter_sdk="$(cd "$(dirname "$flutter_bin")/.." && pwd -P)"
features_file="$flutter_sdk/packages/flutter/lib/src/foundation/_features.dart"
features_backup=""
stage_dir=""
cleanup() {
  if [[ -n "$features_backup" ]]; then
    cp "$features_backup" "$features_file"
    rm -f "$features_backup"
  fi
  if [[ -n "$stage_dir" ]]; then rm -rf "$stage_dir"; fi
}
trap cleanup EXIT
if grep -Fq "bool isWindowingEnabled = debugEnabledFeatureFlags.contains('windowing');" "$features_file"; then
  features_backup="$(mktemp)"
  cp "$features_file" "$features_backup"
  "$python_bin" - "$features_file" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = "bool isWindowingEnabled = debugEnabledFeatureFlags.contains('windowing');"
assert text.count(old) == 1
path.write_text(text.replace(old, "bool isWindowingEnabled = false; // Sonara macOS AOT workaround"))
PY
fi
flutter build macos --release
cleanup
trap - EXIT

app_path="$app_dir/build/macos/Build/Products/Release/sonara.app"
test -d "$app_path"
test -x "$app_path/Contents/MacOS/sonara_engine"
test "$(plutil -extract FLTEnableImpeller raw -o - "$app_path/Contents/Info.plist")" = false
test "$(lipo -archs "$app_path/Contents/MacOS/sonara")" = arm64
test "$(lipo -archs "$app_path/Contents/MacOS/sonara_engine")" = arm64
test "$(lipo -archs "$app_path/Contents/Library/LoginItems/SonaraLogin.app/Contents/MacOS/SonaraLogin")" = arm64
test "$(lipo -archs "$app_path/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS")" = arm64
codesign --verify --deep --strict --verbose=2 "$app_path"

mkdir -p "$dist_dir"
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app_path" "$stage_dir/Sonara.app"
ln -s /Applications "$stage_dir/Applications"
dmg="$dist_dir/Sonara-$version-macos-arm64.dmg"
hdiutil create -volname Sonara -srcfolder "$stage_dir" -ov -format UDZO "$dmg"
cd "$dist_dir"
shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256"
echo "$dmg"
