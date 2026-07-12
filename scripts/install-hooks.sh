#!/usr/bin/env bash
#
# install-hooks.sh — register ClawdIsland's session observer with Claude Code.
#
# Adds three async hooks (SessionStart, PreToolUse, Stop) to ~/.claude/settings.json,
# all pointing at Sources/ClawdIsland/Hooks/session-hook.sh. Existing hooks the user
# has configured are preserved — we merge, never overwrite. Safe to run repeatedly:
# re-running replaces only our own entries instead of piling up duplicates.
#
# Unlike the hook itself (a silent observer), this installer is interactive and will
# fail loudly if something is wrong, so the user knows install didn't take effect.

set -euo pipefail

# --- locate paths -----------------------------------------------------------
script_dir="$(cd "$(dirname "$0")" && pwd)"
hook_script="$(cd "$script_dir/../Sources/ClawdIsland/Hooks" && pwd)/session-hook.sh"
settings="$HOME/.claude/settings.json"
backup="$settings.bak-clawdisland"

# --- preconditions ----------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 1
fi

if [ ! -f "$hook_script" ]; then
  echo "error: hook script not found at $hook_script" >&2
  exit 1
fi

# The command string wired into settings.json — also used to recognise our own
# entries on re-run, so it must stay byte-for-byte identical between installs.
hook_cmd="$hook_script"

# Make the hook executable (harmless if already).
chmod +x "$hook_script"

mkdir -p "$HOME/.claude"

# --- backup once ------------------------------------------------------------
# Only back up an existing settings.json, and never clobber an earlier backup —
# a repeat install must not overwrite the pristine copy with an already-modified one.
if [ -f "$settings" ]; then
  if [ -f "$backup" ]; then
    echo "backup already exists, keeping it: $backup"
  else
    cp "$settings" "$backup"
    echo "backed up existing settings to: $backup"
  fi
  current="$(cat "$settings")"
else
  echo "no existing settings.json, creating a fresh one"
  current="{}"
fi

# --- merge ------------------------------------------------------------------
# For each event: drop any group that already references our hook script (so a
# re-run doesn't duplicate), then append a fresh group. All other groups — the
# user's own hooks — are left exactly as they are. PreToolUse carries no matcher,
# which means it fires for every tool.
updated="$(printf '%s' "$current" | jq \
  --arg cmd "$hook_cmd" '
  def ourgroup: {hooks: [{type: "command", command: $cmd, async: true}]};
  def notours: map(select([.hooks[]?.command] | index($cmd) | not));
  .hooks = (.hooks // {})
  | .hooks.SessionStart = ((.hooks.SessionStart // []) | notours) + [ourgroup]
  | .hooks.PreToolUse   = ((.hooks.PreToolUse   // []) | notours) + [ourgroup]
  | .hooks.Stop         = ((.hooks.Stop         // []) | notours) + [ourgroup]
')"

# Write atomically so a crash can't leave a half-written settings.json.
tmp="$settings.tmp.$$"
printf '%s\n' "$updated" > "$tmp"
mv -f "$tmp" "$settings"

echo "installed ClawdIsland hooks into $settings"
echo "  -> $hook_cmd"
echo "state files will appear in: ~/Library/Application Support/ClawdIsland/state.d/"
echo "open a new 'claude' session for the hooks to take effect."
