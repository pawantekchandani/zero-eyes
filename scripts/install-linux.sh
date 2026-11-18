#!/bin/sh
# Install Zero Eyes for the current user on Linux: the player, its config, the
# Claude Code Stop hook and the OpenCode plugin. The overlay, the Services and
# the LaunchAgent are macOS only (use scripts/install.sh there).
#
#   scripts/install-linux.sh                   # everything it can
#   scripts/install-linux.sh --only player     # one part: player | claude-code | opencode
#   scripts/install-linux.sh --check           # report what is installed; changes nothing
#   scripts/install-linux.sh --uninstall       # remove the install, keep config and history
#   scripts/install-linux.sh --uninstall --purge   # also remove config, state and backups
#
# POSIX sh, not zsh: zsh is not installed on most Linux systems, and plain sh
# (dash, bash, busybox) is. Idempotent: re-running replaces the files it owns.
# The one file it edits in place (~/.claude/settings.json) is backed up first
# and only the Zero Eyes Stop hook is added.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
PLAYER="$BIN_DIR/zero-eyes"
CONFIG_DIR="$HOME/.config/zero-eyes"
HOOK="$HOME/.claude/hooks/zero-eyes-stop.py"
PLUGIN_DIR="$HOME/.config/opencode/plugins"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zero-eyes"
case "${XDG_STATE_HOME:-}" in /*) ;; *) STATE_DIR="$HOME/.local/state/zero-eyes" ;; esac
SETUP="$ROOT/scripts/install-linux.sh"

only=""
check_only=0
uninstall=0
purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) only="${2:-}"; shift ;;
    --check) check_only=1 ;;
    --uninstall) uninstall=1 ;;
    --purge) purge=1 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

say() { printf '  %s\n' "$*"; }

# The python3 that hooks should run: an absolute path, because hooks run with
# a minimal PATH and /usr/bin/python3 is not on every distribution.
PY="$(command -v python3 2>/dev/null || true)"
if [ -z "$PY" ]; then
  echo "python3 not found on PATH; install it first." >&2
  exit 1
fi
HOOK_COMMAND="$PY $HOOK"

config_value() {  # config_value KEY -> the last value of KEY, quotes removed
  [ -f "$CONFIG_DIR/config" ] || return 0
  sed -n "s/^$1=//p" "$CONFIG_DIR/config" | tail -n 1 | tr -d "\"'"
}

install_player() {
  mkdir -p "$BIN_DIR"
  install -m 0755 "$ROOT/bin/zero-eyes" "$PLAYER"

  # Edge voices are optional (ENGINE="edge"). Pin the interpreter that can
  # import edge-tts, since hooks may find a different python3 first.
  py=""
  for candidate in "$HOME/.local/bin/python3" "$PY" /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$candidate" ] || continue
    if "$candidate" -c 'import edge_tts' >/dev/null 2>&1; then
      py="$candidate"
      break
    fi
  done
  if [ -n "$py" ]; then
    sed -i "1s|.*|#!$py|" "$PLAYER"
    say "player      $PLAYER (python: $py)"
  else
    say "player      $PLAYER"
  fi

  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_DIR/config" ]; then
    cat > "$CONFIG_DIR/config" <<'CFG'
# Zero Eyes — voice and playback settings.
VOICE="en-IN-PrabhatNeural"
RATE="+20%"
VOLUME="+0%"
PITCH="+0Hz"
AUTO_READ="true"
MUTED="false"
ENGINE="auto"
PIPER_MODEL=""
CFG
    say "config      $CONFIG_DIR/config (new)"
  else
    say "config      $CONFIG_DIR/config (kept)"
  fi
}

install_claude_code() {
  if [ ! -d "$HOME/.claude" ]; then
    say "claude-code skipped — ~/.claude not found"
    return 0
  fi
  mkdir -p "$(dirname "$HOOK")"
  install -m 0755 "$ROOT/integrations/claude-code/zero-eyes-stop.py" "$HOOK"
  say "hook        $HOOK"

  "$PY" - "$HOME/.claude/settings.json" "$HOOK_COMMAND" <<'PY'
import json, os, shutil, sys, time

settings_path, command = sys.argv[1], sys.argv[2]

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
  if [ ! -d "$HOME/.config/opencode" ]; then
    say "opencode    skipped — ~/.config/opencode not found"
    return 0
  fi
  mkdir -p "$PLUGIN_DIR"
  if [ -e "$PLUGIN_DIR/zero-eyes" ] && [ ! -L "$PLUGIN_DIR/zero-eyes" ]; then
    mv "$PLUGIN_DIR/zero-eyes" "$PLUGIN_DIR/zero-eyes.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  ln -sfn "$ROOT/integrations/opencode" "$PLUGIN_DIR/zero-eyes"
  say "opencode    $PLUGIN_DIR/zero-eyes -> $ROOT/integrations/opencode"
}

# ---------------------------------------------------------------------------
# --uninstall

run_uninstall() {
  [ -x "$PLAYER" ] && "$PLAYER" --stop >/dev/null 2>&1 || true
  if [ -f "$PLAYER" ]; then rm -f "$PLAYER"; say "removed player"; fi
  if [ -L "$PLUGIN_DIR/zero-eyes" ] || [ -e "$PLUGIN_DIR/zero-eyes" ]; then
    rm -rf "$PLUGIN_DIR/zero-eyes"; say "removed opencode plugin"
  fi
  if [ -f "$HOOK" ]; then rm -f "$HOOK"; say "removed claude code hook"; fi
  if [ -f "$HOME/.claude/settings.json" ]; then
    # Any python3 may have been pinned at install time: match on the hook path.
    "$PY" - "$HOME/.claude/settings.json" "$HOOK" <<'PY'
import json, sys
path, hook = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        settings = json.load(f)
except (OSError, ValueError):
    raise SystemExit(0)
ours = lambda e: str(e.get("command", "")).endswith(" " + hook)
groups = settings.get("hooks", {}).get("Stop", [])
changed = False
for group in list(groups):
    entries = [e for e in group.get("hooks", []) if not ours(e)]
    if len(entries) != len(group.get("hooks", [])):
        changed = True
        group["hooks"] = entries
        if not entries:
            groups.remove(group)
if changed:
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print("  removed Stop hook from settings.json")
PY
  fi
  if [ "$purge" -eq 1 ]; then
    if [ -d "$STATE_DIR" ]; then rm -rf "$STATE_DIR"; say "removed state"; fi
    if [ -d "$CONFIG_DIR" ]; then rm -rf "$CONFIG_DIR"; say "removed config"; fi
    find "$HOME/.claude" -maxdepth 1 -name 'settings.json.bak-zero-eyes-*' -delete 2>/dev/null || true
  fi
  echo "Zero Eyes removed."
}

# ---------------------------------------------------------------------------
# --check: read-only report, one line per item. Exit 1 if anything is MISSING.

missing_count=0
row()     { printf '  %-7s %-12s %s\n' "$1" "$2" "$3"; }
fix()     { printf '  %-7s %-12s fix: %s\n' "" "" "$1"; }
ok()      { row OK "$1" "$2"; }
warn()    { row WARN "$1" "$2"; if [ -n "${3:-}" ]; then fix "$3"; fi; }
missing() { row MISSING "$1" "$2"; fix "$3"; missing_count=$((missing_count + 1)); }

# First audio player found for a format, as the player picks it.
find_player() {
  if [ "$1" = "wav" ]; then set -- paplay pw-play ffplay mpv aplay
  else set -- ffplay mpv; fi
  for p in "$@"; do
    if command -v "$p" >/dev/null 2>&1; then echo "$p"; return 0; fi
  done
  return 1
}

# The speech engine and audio player the player will use; the same rules as
# resolve_engine() and audio_player() in bin/zero-eyes.
check_engine() {
  [ -x "$PLAYER" ] || return 0
  engine="$(config_value ENGINE | tr 'A-Z' 'a-z')"
  model="$(config_value PIPER_MODEL)"
  case "$model" in "~/"*) model="$HOME/${model#\~/}" ;; esac
  ext="wav"
  case "$engine" in
    edge)
      ext="mp3"
      py="$(head -n 1 "$PLAYER")"; py="${py#\#!}"
      case "$py" in "/usr/bin/env "*) py="$(command -v "${py#/usr/bin/env }" 2>/dev/null || true)" ;; esac
      if [ -n "$py" ] && "$py" -c 'import edge_tts' >/dev/null 2>&1; then
        ok engine "edge (python: $py)"
      else
        missing engine "ENGINE=\"edge\" but edge-tts is not importable by ${py:-the player's python}" \
          "${py:-python3} -m pip install --user edge-tts && $SETUP --only player"
      fi ;;
    *)
      if [ "$engine" != "espeak" ] && [ -n "$model" ] && [ -f "$model" ] \
         && command -v piper >/dev/null 2>&1; then
        ok engine "piper ($model)"
      else
        if [ "$engine" = "piper" ] || { [ "$engine" != "espeak" ] && [ -n "$model" ]; }; then
          warn engine "piper not used: needs the piper binary on PATH and PIPER_MODEL set to an existing .onnx file"
        fi
        if command -v espeak-ng >/dev/null 2>&1 || command -v espeak >/dev/null 2>&1; then
          ok engine "espeak-ng"
        else
          missing engine "no speech engine (espeak-ng or piper)" \
            "install espeak-ng with your package manager, e.g. sudo apt install espeak-ng"
        fi
      fi ;;
  esac
  if p="$(find_player "$ext")"; then
    ok audio "$p"
  elif [ "$ext" = "mp3" ]; then
    missing audio "Edge voices are MP3 and need ffplay or mpv" "install ffmpeg or mpv"
  else
    missing audio "no audio player (paplay, pw-play, ffplay, mpv, aplay)" \
      "install pulseaudio-utils, pipewire-bin, ffmpeg, mpv or alsa-utils"
  fi
}

run_check() {
  echo "Zero Eyes check"

  if [ -x "$PLAYER" ]; then ok player "$PLAYER"
  else missing player "$PLAYER" "$SETUP --only player"; fi

  check_engine

  if [ -f "$CONFIG_DIR/config" ]; then ok config "$CONFIG_DIR/config"
  else missing config "$CONFIG_DIR/config" "$SETUP --only player"; fi

  if [ -d "$HOME/.claude" ]; then
    if [ -f "$HOOK" ]; then ok hook "$HOOK"
    else missing hook "$HOOK" "$SETUP --only claude-code"; fi
    if "$PY" - "$HOME/.claude/settings.json" "$HOOK_COMMAND" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f:
    stop = json.load(f).get("hooks", {}).get("Stop", [])
found = any(e.get("command") == sys.argv[2] for g in stop for e in g.get("hooks", []))
raise SystemExit(0 if found else 1)
PY
    then ok settings "Stop hook registered in ~/.claude/settings.json"
    else missing settings "Stop hook not in ~/.claude/settings.json" "$SETUP --only claude-code"; fi
  fi

  if [ -d "$HOME/.config/opencode" ]; then
    if [ -L "$PLUGIN_DIR/zero-eyes" ] && [ -d "$PLUGIN_DIR/zero-eyes" ]; then ok opencode "$PLUGIN_DIR/zero-eyes"
    else missing opencode "$PLUGIN_DIR/zero-eyes" "$SETUP --only opencode"; fi
  fi

  echo
  if [ "$missing_count" -eq 0 ]; then echo "Nothing missing."
  else echo "$missing_count item(s) missing."; fi
  [ "$missing_count" -eq 0 ]
}

if [ "$uninstall" -eq 1 ]; then
  run_uninstall
  exit 0
fi

if [ "$check_only" -eq 1 ]; then
  run_check
  exit $?
fi

echo "Zero Eyes install"
if want player; then install_player; fi
if want claude-code; then install_claude_code; fi
if want opencode; then install_opencode; fi

echo
echo "Test it:  printf 'Zero Eyes is installed.' | $PLAYER"

if [ -z "$only" ]; then
  echo
  run_check
fi
