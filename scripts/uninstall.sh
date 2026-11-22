#!/bin/zsh
# Remove Zero Eyes for the current user.
#
#   scripts/uninstall.sh            # remove the install, keep config and history
#   scripts/uninstall.sh --purge    # also remove config, state and settings backups
set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

BIN="$HOME/.local/bin/zero-eyes"
APP="$HOME/Applications/Zero Eyes Overlay.app"
AGENT="$HOME/Library/LaunchAgents/local.zeroeyes.overlay.plist"
HOOK="$HOME/.claude/hooks/zero-eyes-stop.py"
PLUGIN="$HOME/.config/opencode/plugins/zero-eyes"
WATCHER="$HOME/.local/bin/zero-eyes-antigravity"
AG_AGENT="$HOME/Library/LaunchAgents/local.zeroeyes.antigravity.plist"
STATE="$HOME/Library/Application Support/Zero Eyes"
CONFIG="$HOME/.config/zero-eyes"

say() { printf '  %s\n' "$*"; }

pkill -f "ZeroEyesOverlay" >/dev/null 2>&1 || true
"$BIN" --stop >/dev/null 2>&1 || true

if [[ -f "$AGENT" ]]; then
  launchctl bootout "gui/$(id -u)/local.zeroeyes.overlay" >/dev/null 2>&1 || true
  rm -f "$AGENT"
  say "removed launchagent"
fi

if [[ -f "$AG_AGENT" ]]; then
  launchctl bootout "gui/$(id -u)/local.zeroeyes.antigravity" >/dev/null 2>&1 || true
  rm -f "$AG_AGENT"
  say "removed antigravity launchagent"
fi
[[ -f "$WATCHER" ]] && rm -f "$WATCHER" && say "removed antigravity watcher"

[[ -d "$APP" ]] && rm -rf "$APP" && say "removed overlay app"
[[ -f "$BIN" ]] && rm -f "$BIN" && say "removed player"

if [[ -L "$PLUGIN" || -e "$PLUGIN" ]]; then
  rm -rf "$PLUGIN"
  say "removed opencode plugin"
fi

if [[ -f "$HOOK" ]]; then
  rm -f "$HOOK"
  say "removed claude code hook"
fi

if [[ -f "$HOME/.claude/settings.json" ]]; then
  /usr/bin/python3 - "$HOME/.claude/settings.json" "$HOOK" <<'PY'
import json, sys
path, hook = sys.argv[1], sys.argv[2]
command = f"/usr/bin/python3 {hook}"
try:
    with open(path) as f:
        settings = json.load(f)
except (OSError, ValueError):
    raise SystemExit(0)
groups = settings.get("hooks", {}).get("Stop", [])
changed = False
for group in list(groups):
    entries = [e for e in group.get("hooks", []) if e.get("command") != command]
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

for workflow in "$HOME/Library/Services/Zero Eyes Read.workflow" \
                "$HOME/Library/Services/Zero Eyes Stop.workflow" \
                "$HOME/Library/Services/Zero Eyes Reply.workflow"; do
  [[ -d "$workflow" ]] && rm -rf "$workflow" && say "removed ${workflow:t}"
done

if [[ $PURGE -eq 1 ]]; then
  [[ -d "$STATE" ]] && rm -rf "$STATE" && say "removed state"
  [[ -d "$CONFIG" ]] && rm -rf "$CONFIG" && say "removed config"
  find "$HOME/.claude" -maxdepth 1 -name 'settings.json.bak-zero-eyes-*' -delete 2>/dev/null || true
fi

echo "Zero Eyes removed."
