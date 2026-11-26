#!/bin/zsh
# Build a universal (arm64 + x86_64) overlay app and zip it for a GitHub release.
#
#   scripts/package-overlay.sh            # writes dist/ZeroEyesOverlay.zip
#
# Without the variables below the app is ad-hoc signed. To sign it with a
# Developer ID and notarize it (needs a paid Apple Developer account):
#
#   xcrun notarytool store-credentials zero-eyes-notary   # once; asks for Apple ID,
#                                                         # team ID, app-specific password
#   ZERO_EYES_SIGN_ID="Developer ID Application: Name (TEAMID)" \
#   ZERO_EYES_NOTARY_PROFILE=zero-eyes-notary scripts/package-overlay.sh
#
# Then: gh release create vX.Y.Z dist/ZeroEyesOverlay.zip
# scripts/install.sh downloads this zip when swiftc is not installed.
set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
APP="$WORK/Zero Eyes Overlay.app"
BINARY="$APP/Contents/MacOS/ZeroEyesOverlay"
AUDIO_BINARY="$APP/Contents/MacOS/ZeroEyesAudio"

ZERO_EYES_OVERLAY_APP="$APP" "$ROOT/overlay/build.sh" >/dev/null
# Same SDK rule as build.sh: the newest SDK that this swiftc can compile with.
sdks=(${ZERO_EYES_SDK:-} $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -V -r))
for SDK in "${sdks[@]}"; do
  ok=1
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos13.0" \
      "$ROOT/overlay/Overlay.swift" -o "$WORK/overlay-$arch" 2>/dev/null || { ok=0; break; }
    swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos13.0" \
      "$ROOT/overlay/AudioPlayer.swift" -o "$WORK/audio-$arch" 2>/dev/null || { ok=0; break; }
  done
  [[ $ok -eq 1 ]] && break
done
[[ $ok -eq 1 ]] || { echo "No installed SDK builds both architectures." >&2; exit 1; }
lipo -create "$WORK/overlay-arm64" "$WORK/overlay-x86_64" -output "$BINARY"
lipo -create "$WORK/audio-arm64" "$WORK/audio-x86_64" -output "$AUDIO_BINARY"
SIGN_ID="${ZERO_EYES_SIGN_ID:-}"
NOTARY_PROFILE="${ZERO_EYES_NOTARY_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_ID" ]]; then
  echo "ZERO_EYES_NOTARY_PROFILE needs ZERO_EYES_SIGN_ID." >&2; exit 1
fi
if [[ -n "$SIGN_ID" ]]; then
  # Hardened runtime blocks the microphone unless this entitlement is present.
  cat > "$WORK/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
PLIST
  codesign --force --options runtime --timestamp \
    --entitlements "$WORK/entitlements.plist" --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

mkdir -p "$DIST"
rm -f "$DIST/ZeroEyesOverlay.zip"
ditto -c -k --keepParent "$APP" "$DIST/ZeroEyesOverlay.zip"
rm -rf "$WORK"
if [[ -n "$NOTARY_PROFILE" ]]; then signed="Developer ID, notarized"
elif [[ -n "$SIGN_ID" ]]; then signed="Developer ID, not notarized"
else signed="ad-hoc"; fi
echo "Packaged    $DIST/ZeroEyesOverlay.zip (arm64 + x86_64, $signed)"
