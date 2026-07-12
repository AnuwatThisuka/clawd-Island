<div align="center">

# 🦀 Clawd Island

**Your Claude quota, living in the notch.**

[![Latest release](https://img.shields.io/github/v/release/AnuwatThisuka/clawd-island?color=CC785C&label=download)](https://github.com/AnuwatThisuka/clawd-island/releases/latest)
&nbsp;![macOS 14+](https://img.shields.io/badge/macOS-14+-111111?logo=apple&logoColor=white)
&nbsp;[![License MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

Ever caught yourself opening Claude Desktop just to check how close you are to your
5-hour limit? Clawd Island puts that number where you're already looking — the notch.
A small crab and a percentage sit there quietly; tap it and the numbers you actually
care about spread out into a proper dashboard.

## What you get

|                            |                                                                                                                      |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Session ring**           | Live 5-hour and 7-day usage, colour-coded (white → amber → red) so you can tell your status without reading a number |
| **Live tool status**       | While Claude Code is working, the notch shows a green pulse and the tool it's running right now — Bash, Edit, a web fetch — then flips back to your usage % the moment it goes idle (opt-in, see below) |
| **Full breakdown on tap**  | 5-hour, 7-day, extra credits, today's cost, today's token count, and your current plan — six tiles, one click away   |
| **Real reset timers**      | Not estimates — the actual countdown Claude Desktop shows you                                                        |
| **Local cost tracking**    | Today's spend and token count are computed straight from your `~/.claude` logs, no network call needed for that part |
| **A mascot with options**  | Clawd walks around at idle; right-click to swap between the crab, a mono version, or the Claude spark                |
| **Burn-rate ETA**          | Tap the ring to switch from "% used" to "runs out at this rate around 4:20pm"                                        |
| **Threshold alerts**       | Native macOS notification when session or weekly usage first crosses 80% and 95% — no need to glance at the notch    |
| **Opus vs Sonnet split**   | When your plan meters the 7-day limit per model, the tile shows both — "Opus 42% · Sonnet 88%" — not just the higher |
| **Reacts to your pace**    | Clawd's walk speed actually reflects how fast you're burning through the session                                     |
| **Nothing else on screen** | No menu-bar icon competing for space — the island is the interface, right-click for everything else                  |

The whole thing is drawn as an actual notch-shaped window, not a rectangle pretending
to be one — and if your Mac doesn't have a physical notch, it draws a fake one so the
experience is consistent everywhere.

## Where the numbers come from

Clawd Island doesn't have its own account or backend. It borrows a session you're
already logged into — Claude Desktop, or a browser (Chrome, Brave, Edge, Arc, Firefox,
Zen) signed into claude.ai — and asks claude.ai the same question those apps already
ask. That's it. No server of ours sits in the middle, no analytics ride along.

Mechanically: browser cookie stores are encrypted at rest, so the app decrypts the
`claude.ai` session cookie using the same OS Keychain key the browser itself uses to
protect it. macOS will ask you to approve that access the first time — that's the
Keychain prompt you'll see on first launch, and it's expected.

## Getting it running

**macOS 14 or later**, with either Claude Desktop or a browser already signed into
claude.ai.

```bash
git clone https://github.com/AnuwatThisuka/clawd-island.git
cd clawd-island
swift run ClawdIsland
```

That's the fast path for trying it out. For something you can actually drag into
`/Applications`:

```bash
bash scripts/make-app.sh
```

which leaves `Clawd Island.app` (and a zip) in `dist/`.

> If `swift` can't find the right toolchain, point it at a full Xcode install first:
> `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

On first launch, choose **Always Allow** on the Keychain prompt — otherwise it'll ask
again every time you relaunch. Right-click the island afterward and turn on
**Launch at Login** if you want it to just always be there.

## Live tool status (optional)

The notch can also show what Claude Code is doing in real time — a green pulse plus the
tool it's running this instant. This piece is opt-in because it works through Claude
Code's own hooks rather than the usage feed.

**Requires [`jq`](https://jqlang.github.io/jq/):**

```bash
brew install jq
```

Then install the hooks once:

```bash
bash scripts/install-hooks.sh
```

That registers three async hooks (SessionStart, PreToolUse, Stop) in
`~/.claude/settings.json`, all pointing at `Sources/ClawdIsland/Hooks/session-hook.sh`.
The installer backs up any existing settings once to
`settings.json.bak-clawdisland` and **merges** — hooks you've configured yourself are
left untouched, and re-running it never duplicates our entries. Each hook is a passive
observer marked `"async": true`, so it never blocks or slows a Claude Code session; it
just drops a tiny state file under
`~/Library/Application Support/ClawdIsland/state.d/` that the island polls.

Open a new `claude` session for the hooks to take effect. To remove them again:

```bash
bash scripts/uninstall-hooks.sh
```

which strips only our hooks and leaves everything else in place.

## Day to day

- Click the ring to open, click anywhere else to close it
- Click Clawd to cycle mascots
- Right-click for icon settings, pause, threshold alerts, login item, and quit

## Roadmap

Things planned or being considered, roughly ordered by how soon they'd land:

**Next up**

- [ ] Per-project cost — break "tokens/cost today" down by project folder under
      `~/.claude`, not just a single daily total

**Exploring**

- [ ] Usage history — a small trend view (last 7/30 days) built from data already
      being computed for the burn-rate feature, just not persisted yet
- [ ] Multi-account switching — the org is already read from the session; supporting
      more than one signed-in account would mostly be UI work
- [ ] Global hotkey to expand/collapse the island without reaching for the mouse
- [ ] Menu-bar fallback mode for anyone who'd rather not have a notch-shaped window
      at all
- [ ] Thai-language UI (given where this project's early testing happened)

**Longer shot**

- [ ] A companion widget or Lock Screen presence, mirroring the island's state
- [ ] Export today's / this week's usage as CSV or JSON

Have an idea that's not here? Open an issue.

## Credit where it's due

- Clawd Island started as a rename and continuation of
  [stevemcqueenz/claude-notch-tracker](https://github.com/stevemcqueenz/claude-notch-tracker)
  (MIT) — nearly all of the original architecture, the cookie/Keychain usage-fetch
  approach, and the notch UI carry over from that project largely as-is
- The Clawd/Spark animation frames come from Mick Cesanek's
  [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) (MIT)
- The notch-shaped-window technique was worked out by
  [pookify](https://github.com/eyadhammouda/pookify) (MIT)
- "Claude" and the spark mark belong to Anthropic, PBC — referenced here only to
  describe what this app connects to, not as an official Anthropic product

## License

MIT, see [LICENSE](LICENSE).
