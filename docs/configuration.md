# Configuration and state

## Settings

`~/.config/zero-eyes/config` — created by the installer with these defaults:

```
VOICE="en-IN-PrabhatNeural"
RATE="+20%"
VOLUME="+0%"
PITCH="+0Hz"
AUTO_READ="true"
MUTED="false"
ENGINE="apple"
APPLE_VOICE=""
```

| Key | Meaning |
| --- | --- |
| `ENGINE` | `apple` (the Mac's own voices; `auto` and unknown values mean the same), `edge` (Edge voices only), or `say` (`say` speaks directly, without the cache). |
| `PIPER_MODEL` | Linux only. Path to a piper voice model (`.onnx`). When it is set and `piper` is on PATH, piper speaks; otherwise espeak-ng (or espeak) speaks. |
| `APPLE_VOICE` | Apple voice, as a `say -v` name or a voice identifier. Empty picks the best installed English voice: Premium, then Enhanced, then the system voice. Devanagari text goes to an installed Hindi voice (such as Lekha) when there is one. |
| `VOICE` | Edge Read Aloud voice. `edge-tts --list-voices` lists them; Devanagari text switches to `hi-IN-MadhurNeural` on its own. |
| `RATE` | Rate, `+/-N%`, for every engine; for Apple voices `+0%` is 175 words per minute. `-` and `+` in the overlay move it in 10% steps. |
| `VOLUME` | Edge volume, `+/-N%`. |
| `PITCH` | Edge pitch, `+/-NHz`. |
| `MUTED` | Start muted. The overlay's speaker button flips this. |
| `AUTO_READ` | Whether the OpenCode plugin starts reading on its own. |
| `REPLY_MODEL` | Path to a whisper.cpp model for voice replies. Empty (default) uses `ggml-base.en`, downloaded on first use to `models/` in the state folder and checked by SHA-256. |
| `REPLY_LANGUAGE` | Language code passed to `whisper-cli -l`. Default `en`. Use a multilingual model for other languages. |
| `REPLY_SUBMIT` | `true` presses Return after the reply is pasted. Default `false`. |
| `REPLY_SILENCE` | Seconds of silence that end a recording. Default `2`. `0` means only the shortcut or the mic button ends it. Recording always stops after 120 seconds. |

Environment overrides, handy for testing:

| Variable | Effect |
| --- | --- |
| `ZERO_EYES_STATE_DIR` | Put all state somewhere else |
| `ZERO_EYES_ENGINE` | `apple` / `edge` / `say` |
| `ZERO_EYES_VOICE` | Voice |
| `ZERO_EYES_RATE` | Rate |
| `ZERO_EYES_ORIGIN` | The app name the overlay shows |
| `ZERO_EYES_OVERLAY_APP` | Where `overlay/build.sh` writes the app bundle |

On Linux the installer writes `ENGINE="auto"`. The values map like this:

| `ENGINE` | Linux engine |
| --- | --- |
| `auto`, `apple`, `piper`, `say`, unknown | piper when `PIPER_MODEL` and `piper` are both there, else espeak-ng |
| `espeak` | espeak-ng (or espeak) |
| `edge` | Edge voices; needs `edge-tts` and `ffplay` or `mpv` |

`RATE` maps to piper `--length_scale` and to espeak `-s` (`+0%` is 175 words per minute). Devanagari text uses the espeak `hi` voice.

Per-session speaking rules live in `~/.config/zero-eyes/hooks.json`; see
[apps.md](apps.md).

## State

`~/Library/Application Support/Zero Eyes` on macOS, and `$XDG_STATE_HOME/zero-eyes`
(default `~/.local/state/zero-eyes`) on Linux, mode 700:

| File | Holds |
| --- | --- |
| `queue/` | Waiting items, one JSON file each, named by enqueue time |
| `history.json` | The last 50 answers and the current position |
| `now.json` | What is playing now — text, app name, position; the overlay reads this |
| `paused` | Present while paused |
| `player.pid`, `afplay.pid`, `worker.pid` | Live processes |
| `nav` | A pending next/previous/replay request |
| `overlay.pid` | The overlay's pid; `zero-eyes --reply` signals it |
| `reply.wav` | A voice reply while it is recorded and transcribed; deleted after |
| `models/` | The downloaded whisper model |
| `queue.log` | Per-item trace, only when `EDGE_QUEUE_DEBUG` is set |

History is plain text of what was read. Nothing is uploaded anywhere; delete
`history.json` (or the whole folder) to clear it.

## Audio

Speech is synthesized part by part to cached files in `cache/` — AAC (`.m4a`)
made by `say -o` for Apple voices, MP3 for Edge — and played by `/usr/bin/afplay`.
With `ENGINE="say"`, `/usr/bin/say` reads the text directly. On Linux, piper and
espeak-ng make WAV parts, played by the first of `paplay`, `pw-play`, `ffplay`, `mpv`
and `aplay` found on PATH; Edge MP3 parts need `ffplay` or `mpv`. Pause and resume are
signals to the playing process, so they are instant.

The Edge voices come from Microsoft Edge's Read Aloud endpoint through
[`edge-tts`](https://github.com/rany2/edge-tts): unofficial, unauthenticated,
undocumented, and subject to change at any time. That is why they are opt-in.
