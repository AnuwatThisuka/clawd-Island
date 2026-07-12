# Implementation plan — real-time activity redesign

Goal: evolve the current "green dot + tool name" activity indicator into a
floating, verb-based status ("Editing sidebar.tsx", with a live timer) that
hangs with a visible gap below the top edge, instead of fused flush against it.

Reference: user-provided screenshot showing a detached rounded pill, centered
"Editing" headline with an animated underline, a filename subtitle below it,
and an elapsed-time counter (`0:05`) top-right.

This replaces/extends the real-time hook feature already shipped (commit
"Add real-time tool status via Claude Code hooks" — `session-hook.sh`,
`SessionActivityFeed.swift`, `AppModel.swift`, `IslandView.swift`).

Do each phase in order. Stop after each one for confirmation before starting
the next — same rule as every other feature built in this project so far.

---

## Phase A — fix the hook so long-running tools don't go stale

**Problem:** `PreToolUse` fires once, at the start of a tool call. The
liveness window (`liveWithin = 12s` in `SessionActivityFeed.swift`) will
flip the state back to idle mid-tool if the tool runs longer than that —
e.g. a 20-second Bash command. This must be fixed before a timer UI is
built on top of it, or the timer will freeze/disappear while the tool is
still running.

**`Sources/ClawdIsland/Hooks/session-hook.sh`:**

- [x] Add a 4th event: `PostToolUse` — keep writing the state file on this
      event (heartbeat; payload doesn't need to be more than that)
- [x] Split timestamps into two fields:
  - [x] `started_at` — set once, only on `PreToolUse` (idle → running
        transition). Never overwritten by later events for the same run.
  - [x] `updated_at` — heartbeat field, bumped on every event (unchanged
        from today)
- [x] Check `code.claude.com/docs/en/hooks` for any progress/heartbeat-style
      event that fires _during_ a single long-running tool call (not just
      at start/end) — `PostToolUse` alone doesn't cover a slow Bash command
      that's still mid-flight
      → verified: NO such event exists (all 30 events are start/end/lifecycle)
- [x] If no such event exists, raise `liveWithin` to a more forgiving value
      (e.g. 30–45s) as an explicit pragmatic compromise — don't claim this
      is fully solved if it isn't
      → raised 12s → 45s, documented as compromise

**`Sources/ClawdIsland/Model/SessionActivity.swift`:**

- [x] Add `startedAt: Date?` to the struct
      → added as non-optional `startedAt: Date` (feed always supplies a fallback)

**`Sources/ClawdIsland/Core/SessionActivityFeed.swift`:**

- [x] Parse `started_at` from state file JSON
- [x] Fall back to `updated_at` if `started_at` is missing (old/partial
      state files shouldn't crash parsing)
- [x] Re-evaluate whether `liveWithin = 12s` is still right given the point
      above
      → no, raised to 45s

**Tests (`SessionActivityFeedTests.swift`):**

- [x] Fixture: `started_at` far in the past + `updated_at` recent → still
      counts as live (`oldStartWithFreshHeartbeatIsLive`)
- [x] Fixture: missing `started_at` entirely → doesn't crash (fallback path)
      (`missingStartedAtFallsBackToUpdatedAt`)

**Exit criteria:**

- [x] `swift test` passes (27 tests, all green)
- [x] Manual test: deliberately slow Bash command (`sleep 20`) keeps
      showing "running" the whole time, doesn't revert to idle partway
      → NEEDS USER: requires running app + live claude session

---

## Phase B — verb mapping

Extend the existing `prettyToolName` logic (already strips MCP verb
prefixes) with a second mapping: tool name → present-participle verb +
what subtitle to show.

| `tool_name`                  | Verb                                          | Subtitle source                           |
| ---------------------------- | --------------------------------------------- | ----------------------------------------- |
| `Edit`, `MultiEdit`, `Write` | Editing                                       | file basename from `tool_input.file_path` |
| `Read`                       | Reading                                       | file basename                             |
| `Bash`                       | Running                                       | `tool_input.command`, truncated           |
| `Grep`, `Glob`               | Searching                                     | pattern/query field                       |
| `WebFetch`, `WebSearch`      | Researching                                   | domain or query                           |
| anything else (MCP tools)    | fall back to existing `prettyToolName` output | server/action name                        |

**Changes:**

- [x] Verify real field names in `PreToolUse` stdin JSON by piping a real
      event through `jq` and inspecting it — don't guess field names (same
      approach used to debug the plan-tier bug earlier)
      → docs confirm Bash=command, Edit/Write=file_path; Read=file_path,
        Grep/Glob=pattern, WebFetch=url, WebSearch=query (own tool schemas).
        Verified end-to-end by piping real payloads through the hook.
- [x] `session-hook.sh`: extract and write the relevant `tool_input` field
      (file path / command / pattern) into the state file, not just
      `tool_name`
      → new `detail` field, priority: file_path // command // pattern // url // query
- [x] `SessionActivity.swift`: add `verb: String` and `subtitle: String?`
- [x] Decide truncation rules for the subtitle now — long file paths and
      long Bash commands need the same prefix-strip-then-ellipsis treatment
      already applied to MCP tool names, or they'll blow out the pill width
      the same way `list_deployments` did
      → file paths → basename; commands/patterns → whitespace-collapsed; URLs →
        domain; all capped at 28 chars with trailing ellipsis

**Tests:**

- [x] One test per row in the verb-mapping table above
- [x] Fallback case (unmapped tool name)  (`verbFallsBackToPrettyNameForMcp`)

---

## Phase C — window positioning (detached from the top edge)

**Goal:** the pill floats with a visible gap below the screen's top edge,
matching the reference screenshot, instead of being fused flush against it
(current behavior).

**Where this lives:** `Sources/ClawdIsland/System/IslandWindow.swift` and
`Sources/ClawdIsland/UI/NotchShape.swift`.

**Decide before writing code:**

- [x] Confirm reading: collapsed/idle pill stays flush with the physical
      notch (unchanged, matches what's shipped); only the expanded/active
      state gets the gap. The reference screenshot only shows the active
      state — don't assume the idle pill should move too without confirming
      → CONFIRMED with user: gap only when `model.activity != nil` (tool
        running). Idle % + ring AND clicked-open tile grid both stay flush.

**Implementation:**

- [x] Introduce a vertical offset constant (e.g. `activeStateTopGap: CGFloat`)
      applied only when rendering the activity view, not the idle view
      → `IslandView.activeStateTopGap = 12`, applied as top padding in
        `IslandRootView` only when active; click-catcher shifts down to match.
- [x] Re-read the current `IslandWindow.swift` before editing — confirm the
      fixed-size-window-with-repositioned-content approach discussed
      originally still matches the current code (it may have drifted since)
      → still accurate: fixed 260-tall strip flush at screen top, content
        top-anchored in `IslandRootView`; offset achieved via padding, not a
        window resize. `updateInteractiveZone` shifts the hit-rect by the gap.
- [ ] Re-verify the gap looks correct on both notched and non-notched
      (fake-notch) displays — don't regress the multi-display robustness
      work already shipped (`v0.1.4`)
      → NEEDS USER: visual check on both display types.
      → CAVEAT: NotchShape still has concave top flares (built to blend into
        the menu bar). Detached by the gap, those flares hang mid-air and read
        oddly. The proper detached-pill shape belongs to Phase D (content
        redesign); Phase C ships positioning only.

**Tests:**

- [x] No meaningful unit test (pure positioning) — screenshot verification
      only, same workflow as previous UI phases  (build clean, 36 tests green)

---

## Phase D — content redesign

**Goal:** replace the current right-wing "green dot + tool name" compact
view with the full centered layout for the active state only (idle state
keeps showing % + ring, unchanged).

**Layout (from reference):**

- [ ] Centered, bold verb text (e.g. "Editing") with a small animated
      indicator next to it — decide on a concrete SwiftUI animation rather
      than guessing pixel-for-pixel from a static screenshot; a simple
      opacity-pulse on an underline bar beneath the verb is a reasonable,
      cheap interpretation
- [ ] Subtitle below, smaller/muted text — the file/command/query from
      Phase B
- [ ] Elapsed timer, top-right, format `m:ss`, computed live from
      `startedAt` (Phase A)
- [ ] Timer needs its own `Timer`-driven tick separate from the 300ms state
      poll, or the displayed seconds will look choppy

**Changes:**

- [ ] Likely a new dedicated view (e.g. `ActivityDetailView.swift`) rather
      than inline code in `IslandView.swift`, given the layout complexity
      increase from the current compact wing

**Tests:**

- [ ] No meaningful test for pure layout — screenshot verification only
- [ ] If the timer math is extracted into a pure function (elapsed seconds
      → `"m:ss"` string), test that function directly

---

## Cross-cutting checklist (apply to every phase)

- [ ] `git status` clean before starting; stop and report if not
- [ ] No commits without explicit confirmation
- [ ] `swift build` + `swift test` passing before calling a phase done
- [ ] Screenshot verification for anything visual (Phases C and D especially)
- [ ] Diff shown for review before moving to the next phase
- [ ] Field names, thresholds, and API shapes verified against real hook
      output or real docs — not guessed
