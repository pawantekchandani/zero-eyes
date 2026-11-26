#!/bin/zsh
# Rebuild the Zero Eyes floating control panel.
#
# Needs the Xcode command line tools (swiftc). SDK choice is the one thing that
# breaks on some machines: the newest SDK installed can be newer than the
# installed compiler, so the candidates are tried newest-first and the first
# that compiles is used. Override with ZERO_EYES_SDK=/path/to/MacOSX.sdk.
#
# The app is ad-hoc signed, which is enough to run it locally; it is not
# notarized. Everything here is generated, nothing is downloaded.
set -euo pipefail

HERE="${0:A:h}"
SRC="$HERE/Overlay.swift"
AUDIO_SRC="$HERE/AudioPlayer.swift"
APP="${ZERO_EYES_OVERLAY_APP:-$HOME/Applications/Zero Eyes Overlay.app}"
BINARY="$APP/Contents/MacOS/ZeroEyesOverlay"
AUDIO_BINARY="$APP/Contents/MacOS/ZeroEyesAudio"

mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Zero Eyes Overlay</string>
  <key>CFBundleDisplayName</key><string>Zero Eyes Overlay</string>
  <key>CFBundleIdentifier</key><string>local.zeroeyes.overlay</string>
  <key>CFBundleExecutable</key><string>ZeroEyesOverlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Zero Eyes records your spoken reply after you press the reply shortcut or the mic button. The audio is transcribed on this Mac and then deleted.</string>
</dict>
</plist>
PLIST

candidates=()
[[ -n "${ZERO_EYES_SDK:-}" ]] && candidates+=("$ZERO_EYES_SDK")
for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -V -r); do
  candidates+=("$sdk")
done
if command -v xcrun >/dev/null 2>&1; then
  sdk="$(xcrun --show-sdk-path 2>/dev/null || true)"
  [[ -n "$sdk" ]] && candidates+=("$sdk")
fi
candidates+=("")

built=0
for sdk in "${candidates[@]}"; do
  args=(-O -swift-version 5 -target "$(uname -m)-apple-macos13.0")
  [[ -n "$sdk" ]] && args+=(-sdk "$sdk")
  if swiftc "${args[@]}" "$SRC" -o "$BINARY" 2>/dev/null \
     && swiftc "${args[@]}" "$AUDIO_SRC" -o "$AUDIO_BINARY" 2>/dev/null; then
    built=1
    [[ -n "$sdk" ]] && echo "SDK         $sdk"
    break
  fi
done

if [[ $built -eq 0 ]]; then
  echo "Overlay build failed: no installed SDK works with this swiftc." >&2
  echo "Install or update the Xcode command line tools, or set ZERO_EYES_SDK." >&2
  exit 1
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built       $APP"

# App icon, when a source image is in the repo. A top-level, no-Dock app still
# shows this in Finder, Get Info, Login Items and notifications.
ICON_SRC="$HERE/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
  WORK="$(mktemp -d)"
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET" "$APP/Contents/Resources"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
    && echo "Icon        AppIcon.icns"
  if [[ -f "$HERE/MarkTemplate.png" ]]; then
    cp "$HERE/MarkTemplate.png" "$APP/Contents/Resources/MarkTemplate.png"
    echo "Mark        MarkTemplate.png"
  fi
  rm -rf "$WORK"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
