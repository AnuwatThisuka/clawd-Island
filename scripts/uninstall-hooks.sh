#!/usr/bin/env bash
#
# uninstall-hooks.sh — remove ClawdIsland's session observer from Claude Code.
#
# Strips only the hook groups that reference our session-hook.sh, across every
# event, and leaves any other hooks the user configured untouched. Empty event
# arrays and an empty hooks object are cleaned up so settings.json stays tidy.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
hooks_dir="$(cd "$script_dir/../Sources/ClawdIsland/Hooks" && pwd)"
hook_script="$hooks_dir/session-hook.sh"
perm_script="$hooks_dir/permission-hook.sh"
settings="$HOME/.claude/settings.json"

# Must match the command strings install wrote, so we remove exactly what we added.
hook_cmd="$hook_script"
perm_cmd="$perm_script"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 1
fi

if [ ! -f "$settings" ]; then
  echo "no settings.json at $settings — nothing to remove"
  exit 0
fi

# Remove our groups (observer AND permission); drop events that end up empty; drop .hooks if it
# ends up empty.
updated="$(jq --arg cmd "$hook_cmd" --arg perm "$perm_cmd" '
  def notours: map(select([.hooks[]?.command] | (index($cmd) // index($perm)) | not));
  if .hooks then
      .hooks |= with_entries(.value |= notours)
    | .hooks |= with_entries(select(.value | length > 0))
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
  else . end
' "$settings")"

tmp="$settings.tmp.$$"
printf '%s\n' "$updated" > "$tmp"
mv -f "$tmp" "$settings"

echo "removed ClawdIsland hooks from $settings"
echo "your other hooks (if any) were left untouched."
echo "note: the backup at $settings.bak-clawdisland is left in place; remove it manually if you want."
