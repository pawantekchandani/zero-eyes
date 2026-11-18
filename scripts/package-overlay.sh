#!/bin/zsh
# Build a universal (arm64 + x86_64) overlay app and zip it for a GitHub release.
#
#   scripts/package-overlay.sh            # writes dist/ZeroEyesOverlay.zip
#
# Then: gh release create vX.Y.Z dist/ZeroEyesOverlay.zip
# scripts/install.sh downloads this zip when swiftc is not installed.
set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
APP="$WORK/Zero Eyes Overlay.app"
BINARY="$APP/Contents/MacOS/ZeroEyesOverlay"

ZERO_EYES_OVERLAY_APP="$APP" "$ROOT/overlay/build.sh" >/dev/null
# Same SDK rule as build.sh: the newest SDK that this swiftc can compile with.
sdks=(${ZERO_EYES_SDK:-} $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -V -r))
for SDK in "${sdks[@]}"; do
  ok=1
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos13.0" \
      "$ROOT/overlay/Overlay.swift" -o "$WORK/overlay-$arch" 2>/dev/null || { ok=0; break; }
  done
  [[ $ok -eq 1 ]] && break
done
[[ $ok -eq 1 ]] || { echo "No installed SDK builds both architectures." >&2; exit 1; }
lipo -create "$WORK/overlay-arm64" "$WORK/overlay-x86_64" -output "$BINARY"
codesign --force --sign - "$APP"

mkdir -p "$DIST"
rm -f "$DIST/ZeroEyesOverlay.zip"
ditto -c -k --keepParent "$APP" "$DIST/ZeroEyesOverlay.zip"
rm -rf "$WORK"
echo "Packaged    $DIST/ZeroEyesOverlay.zip (arm64 + x86_64)"
