#!/bin/zsh
# Install Zero Eyes for the current user.
#
#   scripts/install.sh                 # everything it can
#   scripts/install.sh --only player   # one part: player | overlay | launchagent
#                                      #           claude-code | opencode | services
#
# Idempotent: re-running replaces the files it owns and leaves everything else
# alone. The one file it edits in place (~/.claude/settings.json) is backed up
# first and only the Zero Eyes Stop hook is added.
set -euo pipefail

ROOT="${0:A:h:h}"
BIN_DIR="$HOME/.local/bin"
PLAYER="$BIN_DIR/zero-eyes"
CONFIG_DIR="$HOME/.config/zero-eyes"
APP="$HOME/Applications/Zero Eyes Overlay.app"
AGENT="$HOME/Library/LaunchAgents/local.zeroeyes.overlay.plist"
HOOK="$HOME/.claude/hooks/zero-eyes-stop.py"
PLUGIN_DIR="$HOME/.config/opencode/plugins"
SERVICES="$HOME/Library/Services"
OVERLAY_ZIP_URL="https://github.com/pawantekchandani/zero-eyes/releases/latest/download/ZeroEyesOverlay.zip"

only=""
if [[ "${1:-}" == "--only" ]]; then only="${2:-}"; fi
want() { [[ -z "$only" || "$only" == "$1" ]]; }

say() { printf '  %s\n' "$*"; }

install_player() {
  mkdir -p "$BIN_DIR"
  install -m 0755 "$ROOT/bin/zero-eyes" "$PLAYER"

  # Hooks run with a minimal PATH, where `python3` may be the system 3.9 that
  # cannot see a pip-installed edge-tts. Pin the interpreter that has it, so the
  # Edge voices are used instead of silently falling back to `say`.
  local py="" candidate
  for candidate in "$HOME/.local/bin/python3" "$(command -v python3 2>/dev/null)" \
                   /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" -c 'import edge_tts' >/dev/null 2>&1; then
      py="$candidate"
      break
    fi
  done
  if [[ -n "$py" ]]; then
    /usr/bin/sed -i '' "1s|.*|#!$py|" "$PLAYER"
    say "player      $PLAYER (python: $py)"
  else
    say "player      $PLAYER (no python with edge-tts found — using macOS say)"
  fi

  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$CONFIG_DIR/config" ]]; then
    cat > "$CONFIG_DIR/config" <<'CFG'
# Zero Eyes — voice and playback settings.
VOICE="en-IN-PrabhatNeural"
RATE="+20%"
VOLUME="+0%"
PITCH="+0Hz"
AUTO_READ="true"
MUTED="false"
ENGINE="auto"
CFG
    say "config      $CONFIG_DIR/config (new)"
  else
    say "config      $CONFIG_DIR/config (kept)"
  fi
}

install_overlay() {
  if command -v swiftc >/dev/null 2>&1; then
    "$ROOT/overlay/build.sh" >/dev/null
    say "overlay     $APP (built)"
    return
  fi
  # No Xcode tools: use the prebuilt, ad-hoc signed app from the latest release.
  local zip
  zip="$(mktemp -d)/ZeroEyesOverlay.zip"
  if curl -fsSL -o "$zip" "$OVERLAY_ZIP_URL"; then
    mkdir -p "$(dirname "$APP")"
    rm -rf "$APP"
    ditto -x -k "$zip" "$(dirname "$APP")"
    say "overlay     $APP (prebuilt release)"
  else
    say "overlay     skipped — no swiftc and the prebuilt download failed"
  fi
}

install_launchagent() {
  if [[ ! -d "$APP" ]]; then
    say "launchagent skipped — build the overlay first"
    return
  fi
  mkdir -p "$(dirname "$AGENT")"
  sed "s|__APP_BINARY__|$APP/Contents/MacOS/ZeroEyesOverlay|" \
    "$ROOT/integrations/launchagent/local.zeroeyes.overlay.plist" > "$AGENT"
  launchctl bootout "gui/$(id -u)/local.zeroeyes.overlay" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/local.zeroeyes.overlay" >/dev/null 2>&1 || true
  say "launchagent $AGENT"
}

install_claude_code() {
  if [[ ! -d "$HOME/.claude" ]]; then
    say "claude-code skipped — ~/.claude not found"
    return
  fi
  mkdir -p "$(dirname "$HOOK")"
  install -m 0755 "$ROOT/integrations/claude-code/zero-eyes-stop.py" "$HOOK"
  say "hook        $HOOK"

  /usr/bin/python3 - "$HOME/.claude/settings.json" "$HOOK" <<'PY'
import json, os, shutil, sys, time

settings_path, hook_path = sys.argv[1], sys.argv[2]
command = f"/usr/bin/python3 {hook_path}"

try:
    with open(settings_path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}
except ValueError:
    print("  claude-code skipped — settings.json is not valid JSON", file=sys.stderr)
    raise SystemExit(0)

hooks = settings.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])
for group in stop:
    for entry in group.get("hooks", []):
        if entry.get("command") == command:
            print("  settings    Stop hook already present")
            raise SystemExit(0)

stop.insert(0, {"hooks": [{"type": "command", "command": command, "async": True}]})

backup = f"{settings_path}.bak-zero-eyes-{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(settings_path, backup) if os.path.exists(settings_path) else None
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"  settings    Stop hook added (backup: {os.path.basename(backup) if os.path.exists(backup) else 'new file'})")
PY
}

install_opencode() {
  if [[ ! -d "$HOME/.config/opencode" ]]; then
    say "opencode    skipped — ~/.config/opencode not found"
    return
  fi
  mkdir -p "$PLUGIN_DIR"
  if [[ -e "$PLUGIN_DIR/zero-eyes" && ! -L "$PLUGIN_DIR/zero-eyes" ]]; then
    mv "$PLUGIN_DIR/zero-eyes" "$PLUGIN_DIR/zero-eyes.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  ln -sfn "$ROOT/integrations/opencode" "$PLUGIN_DIR/zero-eyes"
  say "opencode    $PLUGIN_DIR/zero-eyes -> $ROOT/integrations/opencode"
}

install_services() {
  mkdir -p "$SERVICES"
  for workflow in "$ROOT/integrations/macos-service"/*.workflow; do
    cp -R "$workflow" "$SERVICES/"
    say "service     $SERVICES/${workflow:t}"
  done
  cat <<'TXT'
  services    assign keys in System Settings › Keyboard › Keyboard Shortcuts › Services
              (suggested: Zero Eyes Read ⌃⌥Z, Zero Eyes Stop ⌃⌥X)
TXT
}

echo "Zero Eyes install"
want player      && install_player
want overlay     && install_overlay
want launchagent && install_launchagent
want claude-code && install_claude_code
want opencode    && install_opencode
want services    && install_services

echo
echo "Test it:  printf 'Zero Eyes is installed.' | $PLAYER"
