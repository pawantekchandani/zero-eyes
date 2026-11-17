#!/usr/bin/env python3
"""Claude Code Stop hook: speak the finished answer with Zero Eyes.

Add it to ~/.claude/settings.json (scripts/install.sh does this):

    "Stop": [{"hooks": [
      {"type": "command", "command": "/usr/bin/python3 ~/.zero-eyes/zero-eyes-stop.py",
       "async": true}
    ]}]

The text spoken is the payload's `last_assistant_message`, which is the answer
the turn just produced. Nothing is scraped from the transcript, so a long
session cannot read back an older answer.

Which sessions speak is configuration, not code — see docs/apps.md:

    ~/.config/zero-eyes/hooks.json
    {
      "claude_code": {
        "mode": "all",                  // all | allow | deny  (default: all)
        "skills": ["builder", "gate"],    // role skills, as loaded by the session
        "marker_dir": "~/.zero-eyes/muted"
      }
    }

`mode: deny` stays silent for a session that loaded one of `skills`; `allow`
speaks only those; `all` speaks everything. A file named after the session id
inside `marker_dir` mutes that session whatever the mode. Sub-agent events are
never spoken.
"""
import json
import os
import subprocess
import sys

PLAYER = os.path.expanduser("~/.local/bin/zero-eyes")
CONFIG = os.path.expanduser("~/.config/zero-eyes/hooks.json")


def config():
    """The `claude_code` block, or {} when the file is missing or unreadable."""
    try:
        with open(CONFIG, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    block = data.get("claude_code")
    return block if isinstance(block, dict) else {}


def loaded_skills(transcript):
    """Skill names this session loaded, from main-chain assistant entries."""
    found = set()
    if not transcript:
        return found
    try:
        with open(transcript, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"Skill"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") != "assistant" or entry.get("isSidechain"):
                    continue
                for block in (entry.get("message") or {}).get("content") or []:
                    if (isinstance(block, dict) and block.get("type") == "tool_use"
                            and block.get("name") == "Skill"):
                        skill = (block.get("input") or {}).get("skill")
                        if isinstance(skill, str):
                            found.add(skill)
    except OSError:
        pass
    return found


def marked(event, block):
    """True when a marker file names this session (scripted mute)."""
    marker_dir = block.get("marker_dir")
    session_id = event.get("session_id")
    if not marker_dir or not session_id:
        return False
    return os.path.exists(os.path.join(os.path.expanduser(marker_dir), session_id))


def speaks(event, block):
    """False only when the configuration mutes this session."""
    if event.get("agent_id"):
        return False
    if marked(event, block):
        return False
    mode = str(block.get("mode", "all")).lower()
    skills = {s for s in block.get("skills") or [] if isinstance(s, str)}
    if mode not in ("allow", "deny") or not skills:
        return True
    hit = bool(skills & loaded_skills(event.get("transcript_path") or ""))
    return hit if mode == "allow" else not hit


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0

    block = config()

    if "--dry-run" in sys.argv:
        print(json.dumps({
            "speak": speaks(event, block),
            "mode": block.get("mode", "all"),
            "skills": sorted(loaded_skills(event.get("transcript_path") or "")),
        }))
        return 0

    text = event.get("last_assistant_message") or ""
    if not speaks(event, block) or not text.strip():
        return 0
    try:
        subprocess.run(
            [PLAYER], input=text, text=True, timeout=30,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
