#!/bin/zsh
# Install Zero Eyes for the current user.
#
#   scripts/install.sh                 # everything it can
#   scripts/install.sh --only player   # one part: player | overlay | launchagent
#                                      #           claude-code | opencode | services
#   scripts/install.sh --check         # report what is installed; changes nothing
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

AGENT_LABEL="local.zeroeyes.overlay"

# How the user re-runs setup, for the fix lines --check prints.
case "$ROOT" in
  */Cellar/zero-eyes/*|*/opt/zero-eyes/*) SETUP="zero-eyes-setup" ;;
  *) SETUP="$ROOT/scripts/install.sh" ;;
esac

only=""
check_only=0
if [[ "${1:-}" == "--only" ]]; then only="${2:-}"; fi
if [[ "${1:-}" == "--check" ]]; then check_only=1; fi
want() { [[ -z "$only" || "$only" == "$1" ]]; }

say() { printf '  %s\n' "$*"; }

install_player() {
  mkdir -p "$BIN_DIR"
  install -m 0755 "$ROOT/bin/zero-eyes" "$PLAYER"

  # Edge voices are optional (ENGINE="edge"). Hooks run with a minimal PATH,
  # where `python3` may be the system 3.9 that cannot see a pip-installed
  # edge-tts, so pin the interpreter that has it when there is one.
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
    say "player      $PLAYER (no python with edge-tts: Edge voices unavailable)"
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
ENGINE="apple"
APPLE_VOICE=""
CFG
    say "config      $CONFIG_DIR/config (new)"
  else
    say "config      $CONFIG_DIR/config (kept)"
  fi

  # The Apple engine picks the best installed English voice on its own; the
  # built-in compact voices sound flat, so point at the better ones.
  local voices
  voices="$(/usr/bin/osascript -l JavaScript \
    -e 'ObjC.import("AppKit"); ObjC.unwrap($.NSSpeechSynthesizer.availableVoices).map(ObjC.unwrap).join("\n")' \
    2>/dev/null || true)"
  if ! grep -qE '^com\.apple\.voice\.(premium|enhanced)\.en-' <<<"$voices"; then
    say "voice       no Premium or Enhanced English voice installed; add one in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices"
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
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
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
              (suggested: Zero Eyes Read ⌃⌥Z, Zero Eyes Stop ⌃⌥X, Zero Eyes Reply ⌃⌥R)
TXT
  if ! PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v whisper-cli >/dev/null 2>&1; then
    say "reply       optional: brew install whisper-cpp (needed for Zero Eyes Reply)"
  fi
  say "reply       allow Microphone and Accessibility for Zero Eyes Overlay when asked"
}

# ---------------------------------------------------------------------------
# --check: read-only report, one line per item. Exit 1 if anything is MISSING.

missing_count=0
row()     { printf '  %-7s %-12s %s\n' "$1" "$2" "$3"; }
fix()     { printf '  %-7s %-12s fix: %s\n' "" "" "$1"; }
ok()      { row OK "$1" "$2"; }
warn()    { row WARN "$1" "$2"; [[ -n "${3:-}" ]] && fix "$3"; return 0; }
missing() { row MISSING "$1" "$2"; fix "$3"; missing_count=$((missing_count + 1)); }

# The speech engine the player will use. Kept in one place so it is easy to
# change when the engine choice changes.
check_engine() {
  [[ -x "$PLAYER" ]] || return 0
  local engine="" py voices
  [[ -f "$CONFIG_DIR/config" ]] && engine="$(sed -n 's/^ENGINE="\{0,1\}\([a-z]*\)"\{0,1\}$/\1/p' "$CONFIG_DIR/config" | tail -1)"
  if [[ "$engine" == "edge" ]]; then
    py="$(head -1 "$PLAYER")"
    py="${py#\#!}"
    [[ "$py" == "/usr/bin/env "* ]] && py="$(command -v "${py#/usr/bin/env }" 2>/dev/null || true)"
    if [[ -n "$py" && -x "$py" ]] && "$py" -c 'import edge_tts' >/dev/null 2>&1; then
      ok engine "edge (python: $py)"
    else
      missing engine "ENGINE=\"edge\" but edge-tts is not importable by ${py:-the player's python}" \
        "${py:-python3} -m pip install edge-tts && $SETUP --only player"
    fi
  elif [[ "$engine" == "say" ]]; then
    ok engine "say"
  else
    voices="$(/usr/bin/osascript -l JavaScript \
      -e 'ObjC.import("AppKit"); ObjC.unwrap($.NSSpeechSynthesizer.availableVoices).map(ObjC.unwrap).join("\n")' \
      2>/dev/null || true)"
    if grep -qE '^com\.apple\.voice\.(premium|enhanced)\.en-' <<<"$voices"; then
      ok engine "apple (Premium or Enhanced English voice installed)"
    else
      warn engine "apple, with the basic system voice only" \
        "System Settings › Accessibility › Spoken Content › System Voice › Manage Voices"
    fi
  fi
}

# Shortcut for one Service, from the pasteboard server's prefs. The key looks
# like "(null) - Zero Eyes Read - runWorkflowAsService".
service_shortcut() {
  /usr/bin/python3 - "$HOME/Library/Preferences/pbs.plist" "$1" <<'PY' 2>/dev/null
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        status = plistlib.load(f).get("NSServicesStatus", {})
except Exception:
    raise SystemExit(2)
entry = status.get(f"(null) - {sys.argv[2]} - runWorkflowAsService", {})
key = entry.get("key_equivalent", "")
if key:
    print(key)
else:
    raise SystemExit(1)
PY
}

run_check() {
  local uid name key
  uid="$(id -u)"
  echo "Zero Eyes check"

  if [[ -x "$PLAYER" ]]; then ok player "$PLAYER"
  else missing player "$PLAYER" "$SETUP --only player"; fi

  check_engine

  if [[ -f "$CONFIG_DIR/config" ]]; then ok config "$CONFIG_DIR/config"
  else missing config "$CONFIG_DIR/config" "$SETUP --only player"; fi

  if [[ -d "$APP" ]]; then
    ok overlay "$APP"
    if codesign -v "$APP" >/dev/null 2>&1; then ok signature "valid"
    else missing signature "codesign -v failed" "$SETUP --only overlay"; fi
    if pgrep -f "$APP/Contents/MacOS/ZeroEyesOverlay" >/dev/null 2>&1; then ok running "overlay process found"
    else warn running "overlay not running" "open \"$APP\""; fi
  else
    missing overlay "$APP" "$SETUP --only overlay"
  fi

  if [[ -f "$AGENT" ]]; then
    ok launchagent "$AGENT"
    if launchctl print "gui/$uid/$AGENT_LABEL" >/dev/null 2>&1; then ok loaded "gui/$uid/$AGENT_LABEL"
    else warn loaded "not loaded in gui/$uid (starts at next login)" "launchctl bootstrap gui/$uid \"$AGENT\""; fi
  else
    missing launchagent "$AGENT" "$SETUP --only launchagent"
  fi

  if [[ -d "$HOME/.claude" ]]; then
    if [[ -f "$HOOK" ]]; then ok hook "$HOOK"
    else missing hook "$HOOK" "$SETUP --only claude-code"; fi
    if /usr/bin/python3 - "$HOME/.claude/settings.json" "/usr/bin/python3 $HOOK" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f:
    stop = json.load(f).get("hooks", {}).get("Stop", [])
found = any(e.get("command") == sys.argv[2] for g in stop for e in g.get("hooks", []))
raise SystemExit(0 if found else 1)
PY
    then ok settings "Stop hook registered in ~/.claude/settings.json"
    else missing settings "Stop hook not in ~/.claude/settings.json" "$SETUP --only claude-code"; fi
  fi

  if [[ -d "$HOME/.config/opencode" ]]; then
    if [[ -L "$PLUGIN_DIR/zero-eyes" && -d "$PLUGIN_DIR/zero-eyes" ]]; then ok opencode "$PLUGIN_DIR/zero-eyes"
    else missing opencode "$PLUGIN_DIR/zero-eyes" "$SETUP --only opencode"; fi
  fi

  for name in "Zero Eyes Read" "Zero Eyes Stop" "Zero Eyes Reply"; do
    if [[ -d "$SERVICES/$name.workflow" ]]; then
      ok service "$SERVICES/$name.workflow"
      if key="$(service_shortcut "$name")"; then ok shortcut "$name: $key"
      else warn shortcut "$name: no shortcut found" "System Settings › Keyboard › Keyboard Shortcuts › Services"; fi
    else
      missing service "$SERVICES/$name.workflow" "$SETUP --only services"
    fi
  done

  echo
  if (( missing_count == 0 )); then echo "Nothing missing."
  else echo "$missing_count item(s) missing."; fi
  (( missing_count == 0 ))
}

if (( check_only )); then
  run_check
  exit $?
fi

echo "Zero Eyes install"
want player      && install_player
want overlay     && install_overlay
want launchagent && install_launchagent
want claude-code && install_claude_code
want opencode    && install_opencode
want services    && install_services

echo
echo "Test it:  printf 'Zero Eyes is installed.' | $PLAYER"

if [[ -z "$only" ]]; then
  echo
  run_check
fi
