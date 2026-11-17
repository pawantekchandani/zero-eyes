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
APP="${ZERO_EYES_OVERLAY_APP:-$HOME/Applications/Zero Eyes Overlay.app}"
BINARY="$APP/Contents/MacOS/ZeroEyesOverlay"

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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
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
  args=(-O -swift-version 5)
  [[ -n "$sdk" ]] && args+=(-sdk "$sdk")
  if swiftc "${args[@]}" "$SRC" -o "$BINARY" 2>/dev/null; then
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
