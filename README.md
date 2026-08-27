# Claude Usage

A native macOS menu bar app that shows your Claude plan usage limits — the same numbers as
the Claude desktop app's **Settings → Usage** panel — without opening Claude.

The menu bar title shows a live percentage; clicking it opens the full panel.

```
Plan usage limits — Max (5x)

  Current session  [##··················] 9%   Resets in 4 hr 0 min
  All models       [····················] 2%   Resets in 5d 21 hr
  Fable            [#···················] 3%   Resets in 5d 21 hr
```

---

## Install on another Mac

### 1. Prerequisites

- **macOS 14 (Sonoma) or later.**
- **Swift toolchain.** Full Xcode works, but the Command Line Tools are enough:

  ```sh
  xcode-select --install
  ```

  Verify with `swift --version` (needs 5.9+).

- **Claude Code, signed in.** The app reads the plan percentages using the OAuth token
  Claude Code stores in your login Keychain. Run `claude` once on the new machine and sign
  in before expecting the plan bars to appear. Without it the app still works, but only the
  local token and cost half.

### 2. Clone and build

```sh
git clone git@github.com:mikiastilahun/claude-usage.git
cd claude-usage
./build.sh
```

`build.sh` compiles a release binary, wraps it in `Claude Usage.app`, and ad-hoc signs it.
It takes a few seconds and pulls no third-party dependencies.

### 3. Install and launch

```sh
cp -R "build/Claude Usage.app" /Applications/
open "/Applications/Claude Usage.app"
```

A sparkle icon and a percentage appear in your menu bar. There is no Dock icon and no
window — it's a menu bar app (`LSUIElement`).

**Build on each machine rather than copying the `.app` across.** A bundle copied from
another Mac carries a quarantine flag and an ad-hoc signature made elsewhere, which triggers
Gatekeeper warnings and invalidates any Keychain permission you granted.

### 4. First run

- macOS may ask for permission to read the `Claude Code-credentials` Keychain item. Choose
  **Always Allow**. If you click **Allow** instead, the app asks again the next time the
  token expires (Claude Code refreshes it every few hours). Rebuilding changes the ad-hoc
  signature, so this can be asked once more after an update.
- Open the panel and use the `⋯` menu to pick what the menu bar title shows, and to enable
  **Launch at login**.

### 5. Updating

```sh
cd claude-usage
git pull
./build.sh
pkill -f "Claude Usage.app"
cp -R "build/Claude Usage.app" /Applications/
open "/Applications/Claude Usage.app"
```

Your recorded history is kept outside the app bundle, so updating never loses it.

### Uninstall

```sh
pkill -f "Claude Usage.app"
rm -rf "/Applications/Claude Usage.app"
rm -rf ~/Library/Application\ Support/ClaudeUsage   # deletes recorded history
defaults delete com.mikiastilahun.claudeusage        # preferences
```

---

## What it shows

**Plan usage limits** (the headline, straight from Claude):

- **Current session** — percent of your 5-hour window used, and when it resets.
- **Weekly limits** — "All models" plus any model-scoped bucket (e.g. **Fable**), each with
  its own reset time.

Bars are colour-coded by the severity the API reports, so a limit turns orange and then red
as you approach it. New limit kinds render automatically — the app draws whatever the API
returns rather than hard-coding today's three, so a future bucket appears without a change
here.

**Tokens & cost** (collapsible, from your local transcripts) — the current 5-hour block with
burn rate and projection, Today / 7 days / Month / All totals with the input, output, cache
write and cache read split, a daily bar chart, and per-model and per-project breakdowns.

## Terminal report

The same binary prints everything to stdout, which is handy for a shell status line:

```sh
"/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" --report
```

---

## Where the numbers come from

Two independent sources, because neither alone is enough:

1. **Plan limit percentages** come from `GET https://api.anthropic.com/api/oauth/usage`,
   the endpoint Claude Code's own `/usage` command calls. This is the only source for real
   percentages — your transcripts record tokens, but not what your plan's ceiling is.
2. **Token counts and cost** are computed from `~/.claude/projects/**/*.jsonl` locally.

**The usage endpoint is undocumented.** It is an internal implementation detail, not part of
the public Claude API, and Anthropic may change or remove it at any time. If that happens
the plan section shows an explanatory message and the token/cost half keeps working. The
officially supported alternative is Claude Code's `statusLine` integration, whose JSON
payload includes `rate_limits.five_hour` and `rate_limits.seven_day` — but it only carries
those two windows (no per-model bucket), and only updates while Claude Code is running.

### Credentials

The OAuth token is read from your login Keychain (service `Claude Code-credentials`) fresh
on every request, via the Security framework with a fallback to `/usr/bin/security`.

**The app never writes credentials.** Claude Code owns that Keychain item and refreshes the
token; this app only reads it, so the two can't fight over it. When the token expires the
panel says so and asks you to run `claude` once — deliberately, rather than implementing a
refresh flow that could clobber Claude Code's copy.

Nothing is sent anywhere except that one GET to Anthropic. There is no telemetry.

### Rate limiting

The usage endpoint is itself rate limited, so the app polls it every 5 minutes, caches the
last good response to disk, and backs off for 15 minutes on a 429 — showing the cached
values with a "last updated" note instead of an error, which is how `/usage` behaves too.
Local transcripts are cheap, so those refresh every 15 seconds.

## Durable history

**Claude Code prunes `~/.claude/projects` on its own schedule.** While this app was being
built, a cleanup deleted about a month of transcripts in one pass — 69 files (79 MB) down to
40 (45 MB), which cut the computed all-time total roughly in half.

So the app keeps its own rollup at
`~/Library/Application Support/ClaudeUsage/history.json`: one record per day with totals and
a per-model split. Every scan folds into it using a per-field maximum, which only ever
ratchets upward — a rescan that no longer sees a deleted day cannot erase it. All the
Today / 7 days / Month / All figures read from this rollup, so they stay correct after
Claude Code deletes the transcripts they came from.

The rollup only grows from the day you first run the app; it can't recover transcripts that
were already deleted. It is per-machine and is not synced.

## Cost accuracy

Costs use Anthropic's published API list prices per model, including the cache tiers: cache
reads at 0.1× the base input rate, 5-minute cache writes at 1.25×, and 1-hour writes at 2×.
Transcripts record those two cache tiers separately, so they're priced separately.

Two caveats:

- It's an **API-equivalent** figure. On a subscription you aren't billed this way — read it
  as throughput. The plan limit bars are what actually track against your limits.
- Resuming a session replays earlier messages into a new transcript, so entries are
  deduplicated by message and request ID. On the machine this was built on that meant 9,791
  raw records for 4,444 real ones — skipping that step roughly doubles the numbers.

## Layout

| File | Role |
|---|---|
| `PlanUsageClient.swift` | Keychain read, usage endpoint, backoff |
| `PlanUsage.swift` | Response model; decodes the generic `limits` array |
| `UsageScanner.swift` | Incremental transcript parsing and deduplication |
| `HistoryStore.swift` | Durable daily rollups that survive pruning |
| `Pricing.swift` | Model rates, longest-prefix matched for dated IDs |
| `Analytics.swift` | Aggregation and 5-hour block grouping |
| `MenuPanel.swift` / `LimitBar.swift` | UI |

`UsageAnalytics` backs both the app and `--report`, so the two can't drift apart. Adding a
model is a one-line edit in `Pricing.swift`; an unknown model still counts tokens but
contributes $0, so it undercounts rather than breaking.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Plan bars say "Not signed in to Claude Code" | No Keychain credential. Run `claude` and sign in. |
| Plan bars say "Session token expired" | Run `claude` once; it refreshes the token. This app never writes it. |
| Plan bars say "rate limited" | The endpoint throttled us. It backs off and shows the last known values. |
| Menu bar shows `—` | Plan data hasn't loaded yet, or the endpoint is unavailable. Open the panel for the reason. |
| Repeated Keychain prompts | Expected after each rebuild — the ad-hoc signature changes. Choose **Always Allow**. |
| No icon after launch | It's menu bar only. Check for the sparkle icon; if the bar is full, hide other items. |
