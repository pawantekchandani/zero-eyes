# Integrations

Everything speaks through one player, so adding a harness never means touching
the queue, the overlay or the history.

```sh
printf '%s' "$text" | ~/.local/bin/zero-eyes
```

That is the whole contract. The player queues the text, opens the overlay if it
is not running, works out which app the speech came from, and speaks it in turn.

## Which app the overlay names

The first line of the overlay starts with the app:

1. `ZERO_EYES_ORIGIN` if the caller set it;
2. otherwise the running app that owns the process which queued the speech
   (Claude Code under `Claude.app` says `Claude`, a T3 session says `T3 Code (Beta)`,
   an OpenCode plugin says `OpenCode`);
3. for a macOS Service there is no owning app — the workflow runs detached — so
   it names the frontmost app, i.e. the browser or editor the text was selected in;
4. `Read aloud` if none of that resolves.

If your harness runs in a background process, set `ZERO_EYES_ORIGIN` so the
overlay does not name the host process:

```sh
printf '%s' "$text" | ZERO_EYES_ORIGIN="My Agent" ~/.local/bin/zero-eyes
```

## Claude Code (CLI, desktop app, T3)

`integrations/claude-code/zero-eyes-stop.py` is a **Stop hook**. It speaks the
payload's `last_assistant_message` — the answer the turn just produced — so a
long session never reads an older answer back.

`scripts/install.sh` copies it to `~/.claude/hooks/zero-eyes-stop.py` and adds
one entry to `~/.claude/settings.json`, backing the file up first:

```json
"Stop": [
  { "hooks": [
      { "type": "command",
        "command": "/usr/bin/python3 /Users/you/.claude/hooks/zero-eyes-stop.py",
        "async": true }
  ] }
]
```

`async: true` keeps the hook off the turn's critical path.

Try it without speaking:

```sh
printf '%s' '{"cwd":"/tmp","transcript_path":"","session_id":"t","last_assistant_message":"x"}' \
  | /usr/bin/python3 ~/.claude/hooks/zero-eyes-stop.py --dry-run
```

### Which sessions speak

`~/.config/zero-eyes/hooks.json` — optional; without it every session speaks.

```json
{
  "claude_code": {
    "mode": "deny",
    "skills": ["builder", "gate", "reviewer"],
    "marker_dir": "~/.zero-eyes/muted"
  }
}
```

| Field | Meaning |
| --- | --- |
| `mode` | `all` (default): every session. `deny`: silent for sessions that loaded one of `skills`. `allow`: speak only those. |
| `skills` | Skill names, as loaded by the session — the same signal Claude Code itself uses for roles. |
| `marker_dir` | If a file named after the session id exists here, that session is silent whatever the mode. |

So "speak only my manager sessions" is:

```json
{ "claude_code": { "mode": "allow", "skills": ["manager"] } }
```

and "mute this one session right now" is:

```sh
mkdir -p ~/.zero-eyes/muted && touch ~/.zero-eyes/muted/<session-id>
```

Sub-agent events are never spoken.

## OpenCode

`integrations/opencode/` is a plugin directory. `scripts/install.sh` symlinks it
to `~/.config/opencode/plugins/zero-eyes`, which OpenCode loads on start.

- Every finished answer is spoken once (`auto: false` in the plugin options
  disables that).
- `/zero-eyes` reads the latest answer, or stops speech; `older`, `3`, `list`
  work as arguments; `/zero-eyes-stop` stops.
- `Ctrl+Shift+R` (desktop app) toggles read/stop; the desktop app also binds
  `Ctrl+Alt+Z` to the selected text, matching the macOS Service.

Sub-agent sessions are skipped.

## macOS Services (selected text in any app)

Two Automator workflows:

| Workflow | Runs |
| --- | --- |
| `Zero Eyes Read.workflow` | `~/.local/bin/zero-eyes` (the player copies the selection itself with ⌘C) |
| `Zero Eyes Stop.workflow` | `~/.local/bin/zero-eyes --stop` |

`scripts/install.sh` copies them to `~/Library/Services`. Assign keys in
**System Settings › Keyboard › Keyboard Shortcuts › Services**; suggested ⌃⌥Z and
⌃⌥X. They appear in the Services menu and the right-click menu of any app.

Safari can be slow to hand the shortcut to a Service right after it gains focus;
the Services menu item always works.

## Anything else

Five lines, no plugin API:

```sh
speak() { printf '%s' "$1" | ZERO_EYES_ORIGIN="My Tool" ~/.local/bin/zero-eyes; }
speak "The job finished with three warnings."
```

Because the player owns the queue, several harnesses can speak at once without
talking over each other, and the overlay shows one list for all of them.
