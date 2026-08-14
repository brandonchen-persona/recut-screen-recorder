#!/bin/bash
# Builds Recut.app. There is no Xcode project — SwiftPM produces the binary and
# this script wraps it in a bundle, because macOS only grants Screen Recording
# permission to a signed .app with a stable bundle identifier.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Recut.app"

cd "$ROOT"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product Recut
BIN="$(swift build -c "$CONFIG" --product Recut --show-bin-path)/Recut"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Recut"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Recut</string>
    <key>CFBundleDisplayName</key>       <string>Recut</string>
    <key>CFBundleExecutable</key>        <string>Recut</string>
    <key>CFBundleIdentifier</key>        <string>com.recut.app</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Recut records your microphone alongside your screen, so you can narrate a demo. Audio stays on this Mac.</string>
    <key>NSCameraUsageDescription</key>
    <string>Recut records your camera alongside your screen, to show you in the corner of a demo. Video stays on this Mac.</string>
</dict>
</plist>
PLIST

# The binary swiftc emits is already ad-hoc "linker-signed", which is enough to
# launch and to be granted Screen Recording. Re-signing the bundle is therefore
# opt-in: on machines running a binary authorization agent (Santa and friends)
# a freshly re-signed bundle has an unknown hash and gets SIGKILLed on exec.
if [[ "${SIGN:-0}" == "1" ]]; then
    cat > "$ROOT/build/Recut.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT
    echo "==> Signing (SIGN=1)"
    codesign --force --sign "${SIGN_IDENTITY:--}" \
        --entitlements "$ROOT/build/Recut.entitlements" \
        --timestamp=none \
        "$APP"
fi

echo "==> Checking the bundle launches"
if ! "$APP/Contents/MacOS/Recut" --help >/dev/null 2>&1; then
    echo "!! The bundled binary would not start."
    echo "!! If this machine runs Santa or similar, an ad-hoc signature is"
    echo "!! blocked — rebuild without SIGN=1, or have the hash allowlisted."
    exit 1
fi

# Screen Recording is granted against the code signature. Without a certificate
# that signature is an ad-hoc cdhash, which changes whenever the binary does —
# so a rebuild silently invalidates the grant while System Settings still shows
# the old entry switched on.
CDHASH="$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
STAMP="$ROOT/build/.last-cdhash"
if [[ -f "$STAMP" && "$(cat "$STAMP")" != "$CDHASH" ]]; then
    echo
    echo "!! This build has a new code signature, so any existing Screen"
    echo "!! Recording grant no longer applies. Clear the stale entry with:"
    echo
    echo "     tccutil reset ScreenCapture com.recut.app"
    echo
    echo "!! then launch Recut and use \"Request access\"."
fi
echo "$CDHASH" > "$STAMP"

echo "==> Built $APP  (cdhash ${CDHASH:0:16})"
