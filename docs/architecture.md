# Architecture

Four programs, one owner of the audio.

```
  Claude Code Stop hook ─┐
  OpenCode plugin    ────┼──>  zero-eyes  ──>  say -o (m4a) or edge-tts (mp3)  ──>  afplay
  macOS Service      ────┤     (enqueue)
  anything (pipe)    ────┘          │
                                    │ writes queue/, now.json, history.json
                                    ▼
                             ~/Library/Application Support/Zero Eyes
                                    ▲
                                    │ reads every 0.5 s
                             Zero Eyes Overlay (AppKit panel)
```

## Enqueue

Every surface runs the same command and exits immediately:

```sh
printf '%s' "$text" | zero-eyes
```

`enqueue()` cleans the markdown, works out the voice (Hindi text gets the Hindi
voice) and the owning app, then writes one JSON file into `queue/` under a name
that starts with the enqueue time. It then drops the oldest waiting items beyond
three, starts a worker if none is running, and returns.

The app name comes from `ZERO_EYES_ORIGIN`, else the app that owns the calling
process (`lsappinfo`), else the frontmost app. A Services workflow runs detached,
so that last fallback is what names your browser.

## Play

`zero-eyes --drain` is the worker. It takes an exclusive `flock`, writes its pid,
and loops:

1. act on a pending `nav` request (prev/next/replay) by playing from `history.json`;
2. otherwise pop the oldest queued item, record it in history, write `now.json`,
   synthesize and play it;
3. exit when the queue is empty.

Synthesis writes each part to a cached file — `say -v <voice> -r <wpm> -o` (AAC)
for the default Apple engine, `edge_tts.Communicate(...).save()` (MP3) with
`ENGINE="edge"` — then plays it with `afplay`. If the Apple engine cannot make the
first part, the same text goes straight to `say`. Stop and pause signal the
playing child, so they are immediate even mid-sentence.

Because there is one worker, several harnesses can enqueue at the same time and
still be played one after another.

## Queue policy

At most three items wait. A fourth arrival deletes the oldest waiting one; the
item already playing is untouched. This is deliberate: an agent can produce
answers faster than speech, and a strict FIFO turns into reading ten-minute-old
text. Three is enough that back-to-back answers from two sessions are both heard.

## Overlay

A borderless `NSPanel` (`LSUIElement`, no Dock icon) that reads the state files
directly every half second — no IPC, no extra process while idle. Buttons call
the player with `--stop`, `--next`, `--previous`, `--replay`, `--pause`, `--mute`,
`--rate-up`, `--rate-down`. The panel is started at login by a LaunchAgent and
re-started by the player whenever anything is spoken.

Voice reply is the one exception to "no IPC". `zero-eyes --reply` sends `SIGUSR1`
to the pid in `overlay.pid`, and the overlay starts or stops recording. The overlay
calls `--reply-begin` (checks `whisper-cli`, stops speech), records with
`AVAudioRecorder` to `reply.wav`, then calls `--reply-transcribe` (runs `whisper-cli`,
deletes the file) and pastes the text with a synthetic ⌘V. Recording and pasting live
in the overlay so that Microphone and Accessibility permission belong to one app.

## Failure behaviour

- `edge-tts` missing, offline, or the endpoint changed → silence with
  `ENGINE="edge"`; the default Apple engine needs neither.
- Overlay missing → speech still works; the player skips the launch.
- Worker killed mid-item → the item is already in history; `--replay` reads it again.
- Stale state after a crash → pid files are checked with `kill -0` and discarded
  when the process is gone.
