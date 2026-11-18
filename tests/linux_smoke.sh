#!/bin/sh
# End-to-end smoke test of the player on Linux: espeak-ng makes WAV parts into
# the cache, paplay plays them, and pause / resume / stop act on paplay.
#
# Needs espeak-ng, paplay and a running sound server. CI has no sound card, so
# it runs PulseAudio with its null sink (see .github/workflows/tests.yml); the
# null sink consumes audio in real time, like a real device.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAYER="$ROOT/bin/zero-eyes"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# Keep the sound server reachable after HOME changes: PulseAudio finds its
# socket and cookie through HOME.
server="$(pactl info 2>/dev/null | sed -n 's/^Server String: //p')"
[ -n "$server" ] || fail "no sound server (pactl info failed)"
PULSE_SERVER="$server"
PULSE_COOKIE="$HOME/.config/pulse/cookie"
export PULSE_SERVER PULSE_COOKIE

HOME="$(mktemp -d)"            # no user config: the default ENGINE (auto) is used
ZERO_EYES_STATE_DIR="$HOME/state"
export HOME ZERO_EYES_STATE_DIR
STATE="$ZERO_EYES_STATE_DIR"

wait_idle() {  # wait_idle SECONDS
  i=0
  while "$PLAYER" --status; do
    i=$((i + 1))
    [ "$i" -le $(($1 * 10)) ] || fail "player still busy after $1 s"
    sleep 0.1
  done
}

audio_pid() {  # the live audio player pid, or nothing
  pid="$(cat "$STATE/afplay.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && [ -d "/proc/$pid" ] && echo "$pid"
  return 0
}

proc_state() { awk '{print $3}' "/proc/$1/stat"; }

command -v espeak-ng >/dev/null || fail "espeak-ng not installed"

# 1. A short answer is synthesized to WAV, played to the end, and recorded.
printf '%s' "Zero Eyes smoke test. First part." | "$PLAYER"
wait_idle 30
wavs="$(find "$STATE/cache" -name '*.wav' -size +0 | wc -l)"
[ "$wavs" -ge 1 ] || fail "no WAV part in $STATE/cache"
first="$(find "$STATE/cache" -name '*.wav' | head -n 1)"
[ "$(head -c 4 "$first")" = "RIFF" ] || fail "$first is not a WAV file"
case "$first" in *"_+0%.wav") ;; *) fail "part name does not carry the rate: $first" ;; esac
grep -q "Zero Eyes smoke test" "$STATE/history.json" || fail "answer not in history"
pass "espeak-ng made $wavs WAV part(s) and the answer is in history"

# 2. Pause stops the audio player (SIGSTOP), resume continues it, stop ends it.
long="This answer is long enough to pause. It has several sentences in it."
long="$long $long $long $long"
printf '%s' "$long" | "$PLAYER"
i=0
until pid="$(audio_pid)" && [ -n "$pid" ]; do
  i=$((i + 1)); [ "$i" -le 300 ] || fail "audio player never started"
  sleep 0.1
done
[ "$(cat "/proc/$pid/comm")" = "paplay" ] || fail "audio player is not paplay"
pass "paplay is playing (pid $pid)"

"$PLAYER" --pause
sleep 0.5
[ "$(proc_state "$pid")" = "T" ] || fail "paplay not stopped after --pause"
"$PLAYER" --now | grep -q '"state": "paused"' || fail "--now does not say paused"
pass "--pause stopped paplay"

"$PLAYER" --pause
sleep 0.5
[ -d "/proc/$pid" ] || fail "paplay died on resume"
[ "$(proc_state "$pid")" != "T" ] || fail "paplay still stopped after resume"
pass "--pause again resumed paplay"

"$PLAYER" --stop
wait_idle 5
[ ! -d "/proc/$pid" ] || [ "$(proc_state "$pid")" = "Z" ] || fail "paplay still running after --stop"
pass "--stop ended playback"

echo "Linux smoke test passed."
