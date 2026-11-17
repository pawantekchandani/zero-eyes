<p align="center">
  <img src="overlay/AppIcon.png" width="128" alt="Zero Eyes">
</p>

# Zero Eyes

Reads your AI coding agent's answers aloud on macOS, so you can look away from the screen and still follow the work.

```
┌───────────────────────────────────────────────────────────────┐
│  ⏮   ⏯   ⏹   ⏭   🔇   −   +20%   +   ⌃   ✕                  │
│  Claude · The build passed and the PR is open, waiting on CI… │
│  Answer 12 of 40 · 2 queued                                   │
└───────────────────────────────────────────────────────────────┘
```

- **Speaks the answer, not your screen.** Each finished answer is read once, from the text the agent actually produced.
- **One shared queue.** Claude Code, OpenCode and any text you select can all speak through the same player; the newest three wait, the rest are dropped so nothing goes stale.
- **A floating bar you can actually use.** Pause, stop, step through recent answers, change speed, or mute everything while the queue keeps draining silently.
- **Knows which app is talking.** The first line names the app the speech came from: `Claude`, `T3 Code`, `OpenCode`, `Google Chrome`, and so on.
- **Select text and press a key.** A macOS Service reads the selection in any app.

## Requirements

- macOS 13 or later
- `python3`
- [`edge-tts`](https://github.com/rany2/edge-tts) for Microsoft Edge's Read Aloud voices:
  `python3 -m pip install --user edge-tts`. The installer pins whichever `python3`
  can import it into the player's shebang, because hooks run with a minimal PATH
  where the wrong interpreter would be found.
- Xcode command line tools, only for the floating overlay (`swiftc`)

Without `edge-tts` the player falls back to macOS `say`, so it still works — just
with the system voice. Install it, re-run `scripts/install.sh`, and the Edge
voices take over. Set `ENGINE="edge" | "say" | "auto"` in the config to choose.

## Install

```sh
git clone https://github.com/<you>/zero-eyes.git
cd zero-eyes
scripts/install.sh
```

That installs the player to `~/.local/bin/zero-eyes`, builds and starts the overlay, adds the login agent, wires the Claude Code Stop hook, links the OpenCode plugin, and copies the two macOS Services.

Install one piece at a time with `scripts/install.sh --only player|overlay|launchagent|claude-code|opencode|services`.

Then assign shortcuts in **System Settings › Keyboard › Keyboard Shortcuts › Services**: `Zero Eyes Read` (suggested ⌃⌥Z) and `Zero Eyes Stop` (suggested ⌃⌥X).

Test it:

```sh
printf '%s' "Zero Eyes is installed." | ~/.local/bin/zero-eyes
```

## Use

The overlay appears with the first thing spoken and can be dragged anywhere; it remembers its place and whether it was collapsed.

| Button | Action |
| --- | --- |
| ⏮ / ⏭ | previous / next answer in the shared history |
| ⏯ | pause, resume; when idle, replay the last answer |
| ⏹ | stop and clear the queue |
| 🔇 | mute all output — the queue keeps draining, nothing piles up |
| − / + | speech rate in 10% steps, from the next item |
| ⌃ / ⌄ | collapse to a small pill |
| ✕ | quit the overlay |

From the terminal:

```sh
printf '%s' "text" | zero-eyes   # queue it
zero-eyes --now                  # state as one JSON line
zero-eyes --stop | --pause | --mute | --next | --previous | --replay
zero-eyes --rate-up | --rate-down
```

## How the queue behaves

One worker plays items in order, one at a time. Only the newest three may wait; a fourth arrival drops the oldest waiting item. Whatever is already speaking is never cut off. That keeps a fast agent from building a backlog you hear ten minutes later, while still letting two quick answers from different sessions both get heard.

## Integrations

| Harness | How | Where |
| --- | --- | --- |
| Claude Code (CLI, desktop, T3) | Stop hook speaks `last_assistant_message` | `integrations/claude-code/` |
| OpenCode | Plugin speaks finished answers; `/zero-eyes`, `/zero-eyes-stop` | `integrations/opencode/` |
| Any app, selected text | macOS Services: `Zero Eyes Read`, `Zero Eyes Stop` | `integrations/macos-service/` |
| Anything else | `printf '%s' "$text" \| zero-eyes` | `integrations/generic/example.sh` |

Per-session rules (speak only certain roles, mute a session) are configuration, not code: see [docs/apps.md](docs/apps.md).

## Configuration

`~/.config/zero-eyes/config`:

| Key | Default | Meaning |
| --- | --- | --- |
| `VOICE` | `en-IN-PrabhatNeural` | Edge voice; `edge-tts --list-voices` shows all |
| `RATE` | `+0%` | Edge speaking rate |
| `VOLUME` | `+0%` | Edge volume |
| `PITCH` | `+0Hz` | Edge pitch |
| `ENGINE` | `auto` | `auto` = Edge then `say`, `edge` = Edge only, `say` = `say` only |
| `MUTED` | `false` | muted at start |
| `AUTO_READ` | `true` | whether OpenCode auto-read starts on |

Details, state files and overrides: [docs/configuration.md](docs/configuration.md).

## Notes

- Speech uses Microsoft Edge's own Read Aloud voice endpoint through the unofficial [`edge-tts`](https://github.com/rany2/edge-tts) package. No key, no account, no quota — and no guarantee: it is undocumented and Microsoft can change or block it at any time. `ENGINE="auto"` falls back to macOS `say` when that happens. Using that endpoint is your call and your responsibility.
- Nothing leaves your machine except the text sent to that voice endpoint. No telemetry, no accounts.
- State is per-user, in `~/Library/Application Support/Zero Eyes` (mode 700): the queue, the last 50 answers, and the current item. Delete that folder to clear history.
- Not affiliated with ZeroEyes Inc. or any other company of a similar name — this is an independent listening tool for your own machine, not a security or surveillance product.
- The overlay is ad-hoc signed and built locally; it is not notarized, and it is started by path rather than through LaunchServices for that reason.

## Uninstall

```sh
scripts/uninstall.sh           # remove the install, keep config and history
scripts/uninstall.sh --purge   # also remove config, state and backups
```

## License

MIT — see [LICENSE](LICENSE).
