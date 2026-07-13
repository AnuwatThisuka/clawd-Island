#!/usr/bin/env bash
#
# install-hooks.sh — register ClawdIsland's session observer with Claude Code.
#
# Adds four async hooks (SessionStart, PreToolUse, PostToolUse, Stop) to ~/.claude/settings.json,
# all pointing at Sources/ClawdIsland/Hooks/session-hook.sh. Existing hooks the user
# has configured are preserved — we merge, never overwrite. Safe to run repeatedly:
# re-running replaces only our own entries instead of piling up duplicates.
#
# Unlike the hook itself (a silent observer), this installer is interactive and will
# fail loudly if something is wrong, so the user knows install didn't take effect.

set -euo pipefail

# --- locate paths -----------------------------------------------------------
script_dir="$(cd "$(dirname "$0")" && pwd)"
hooks_dir="$(cd "$script_dir/../Sources/ClawdIsland/Hooks" && pwd)"
hook_script="$hooks_dir/session-hook.sh"
perm_script="$hooks_dir/permission-hook.sh"
settings="$HOME/.claude/settings.json"
backup="$settings.bak-clawdisland"

# Tools gated by the permission hook. Regex matched against the tool name by Claude Code:
# mutating/shell/web + all MCP tools. Reads (Read/Grep/Glob) pass through untouched, keeping
# their normal flow. Everything not matched here never triggers the blocking hook.
perm_matcher="Bash|Write|Edit|MultiEdit|NotebookEdit|WebFetch|mcp__.*"

# --- preconditions ----------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 1
fi

if [ ! -f "$hook_script" ]; then
  echo "error: hook script not found at $hook_script" >&2
  exit 1
fi

if [ ! -f "$perm_script" ]; then
  echo "error: permission hook not found at $perm_script" >&2
  exit 1
fi

# The command strings wired into settings.json — also used to recognise our own entries on
# re-run, so they must stay byte-for-byte identical between installs.
hook_cmd="$hook_script"
perm_cmd="$perm_script"

# Make the hooks executable (harmless if already).
chmod +x "$hook_script" "$perm_script"

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
# For each event: drop any group that already references either of our hook scripts (so a
# re-run doesn't duplicate), then append fresh groups. All other groups — the user's own
# hooks — are left exactly as they are.
#
# Observer (session-hook.sh): async, matcher-less, fires for every tool on SessionStart /
# PreToolUse / PostToolUse / Stop. PostToolUse is the heartbeat that keeps a multi-tool turn
# continuously live (see session-hook.sh).
#
# Permission gate (permission-hook.sh): SYNCHRONOUS (no async flag) so Claude Code waits for its
# stdout decision, scoped by $matcher to the gated tool set. It shares PreToolUse with the
# observer as a second, separate group — Claude Code runs both; only this one can block.
updated="$(printf '%s' "$current" | jq \
  --arg cmd "$hook_cmd" \
  --arg perm "$perm_cmd" \
  --arg matcher "$perm_matcher" '
  def obsgroup:  {hooks: [{type: "command", command: $cmd,  async: true}]};
  def permgroup: {matcher: $matcher, hooks: [{type: "command", command: $perm}]};
  def notours: map(select([.hooks[]?.command] | (index($cmd) // index($perm)) | not));
  .hooks = (.hooks // {})
  | .hooks.SessionStart = ((.hooks.SessionStart // []) | notours) + [obsgroup]
  | .hooks.PreToolUse   = ((.hooks.PreToolUse   // []) | notours) + [obsgroup, permgroup]
  | .hooks.PostToolUse  = ((.hooks.PostToolUse  // []) | notours) + [obsgroup]
  | .hooks.Stop         = ((.hooks.Stop         // []) | notours) + [obsgroup]
')"

# Write atomically so a crash can't leave a half-written settings.json.
tmp="$settings.tmp.$$"
printf '%s\n' "$updated" > "$tmp"
mv -f "$tmp" "$settings"

echo "installed ClawdIsland hooks into $settings"
echo "  observer   -> $hook_cmd"
echo "  permission -> $perm_cmd  (gates: $perm_matcher)"
echo "state files will appear in:  ~/Library/Application Support/ClawdIsland/state.d/"
echo "approval requests appear in: ~/Library/Application Support/ClawdIsland/permissions.d/"
echo "open a new 'claude' session for the hooks to take effect."
