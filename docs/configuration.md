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
ENGINE="auto"
```

| Key | Meaning |
| --- | --- |
| `VOICE` | Edge Read Aloud voice. `edge-tts --list-voices` lists them; Devanagari text switches to `hi-IN-MadhurNeural` on its own. |
| `RATE` | Edge rate, `+/-N%`. `-` and `+` in the overlay move it in 10% steps. |
| `VOLUME` | Edge volume, `+/-N%`. |
| `PITCH` | Edge pitch, `+/-NHz`. |
| `ENGINE` | `auto` (Edge, then macOS `say`), `edge`, or `say`. |
| `MUTED` | Start muted. The overlay's speaker button flips this. |
| `AUTO_READ` | Whether the OpenCode plugin starts reading on its own. |

Environment overrides, handy for testing:

| Variable | Effect |
| --- | --- |
| `ZERO_EYES_STATE_DIR` | Put all state somewhere else |
| `ZERO_EYES_ENGINE` | `auto` / `edge` / `say` |
| `ZERO_EYES_VOICE` | Voice |
| `ZERO_EYES_RATE` | Rate |
| `ZERO_EYES_ORIGIN` | The app name the overlay shows |
| `ZERO_EYES_OVERLAY_APP` | Where `overlay/build.sh` writes the app bundle |

Per-session speaking rules live in `~/.config/zero-eyes/hooks.json`; see
[apps.md](apps.md).

## State

`~/Library/Application Support/Zero Eyes` (mode 700):

| File | Holds |
| --- | --- |
| `queue/` | Waiting items, one JSON file each, named by enqueue time |
| `history.json` | The last 50 answers and the current position |
| `now.json` | What is playing now — text, app name, position; the overlay reads this |
| `paused` | Present while paused |
| `player.pid`, `afplay.pid`, `worker.pid` | Live processes |
| `nav` | A pending next/previous/replay request |
| `queue.log` | Per-item trace, only when `EDGE_QUEUE_DEBUG` is set |

History is plain text of what was read. Nothing is uploaded anywhere; delete
`history.json` (or the whole folder) to clear it.

## Audio

Speech is synthesized to a temporary MP3 and played by `/usr/bin/afplay`, or
read directly by `/usr/bin/say` when Edge TTS is unavailable or `ENGINE="say"`.
Pause and resume are signals to the playing process, so they are instant.

The Edge voices come from Microsoft Edge's Read Aloud endpoint through
[`edge-tts`](https://github.com/rany2/edge-tts): unofficial, unauthenticated,
undocumented, and subject to change at any time. `ENGINE="auto"` keeps the tool
usable when it breaks.
