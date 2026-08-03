# Claude Usage Bar

A macOS menu bar widget that shows your Claude usage limits at a glance — session and weekly percentages, with live reset countdowns.

```
􀙭 30% · 42%
```

Click it for the full breakdown: one row per limit window, each with a status-colored meter, the exact percentage, and how long until it resets.

## Requirements

- macOS 13 (Ventura) or later, Apple silicon or Intel
- Xcode command line tools — `xcode-select --install`
- Claude Code installed and signed in (the widget reads your existing session; it never asks for credentials)

## Install

### Homebrew

```bash
brew install nexusgen4561/tap/claude-usage-bar
open -a ~/Applications/"Claude Usage.app"
```

### From source

```bash
git clone https://github.com/nexusgen4561/claude-usage-bar.git
cd claude-usage-bar
./build.sh
open -a ~/Applications/"Claude Usage.app"
```

`build.sh` compiles a universal binary, assembles `~/Applications/Claude Usage.app`, and ad-hoc signs it. Nothing is installed system-wide. Pass `APP_DIR=/Applications` to build somewhere else.

Both routes compile on your machine rather than downloading a prebuilt binary, and that's deliberate — an unsigned app pulled off the internet gets quarantined by Gatekeeper and refuses to launch. Compiling locally sidesteps that entirely.

## Using it

The icon shows your session and weekly-all percentages, colored by pressure (green under 60%, amber, orange, red at 95%+). It dims to gray when the data is stale. Hover for a tooltip.

From the dropdown:

| Item | What it does |
| --- | --- |
| **Refresh now** (⌘R) | Polls immediately, bypassing the backoff clock |
| **Open usage settings…** | Opens claude.ai/settings/usage |
| **Launch at login** | Installs a LaunchAgent at `~/Library/LaunchAgents/com.local.claudeusagebar.plist` |
| **Quit** (⌘Q) | Stops the widget |

You'll see a row for every limit window your account actually has. Most accounts have two — session and weekly across all models. Per-model windows (Opus, Sonnet, Cowork) and extra-usage credits appear automatically when your plan includes them; no update needed.

## How it gets the data

It reads your Claude Code OAuth token out of the login keychain (item `Claude Code-credentials`, the same one `claude` itself uses) and calls `GET https://api.anthropic.com/api/oauth/usage` — the endpoint behind `/usage` in Claude Code and the usage page on claude.ai.

The token is read fresh on every poll, so a token Claude Code refreshes in the background is picked up without restarting the widget. Nothing is written anywhere, nothing is sent anywhere except to Anthropic's own API, and there is no telemetry.

Two constraints are baked in, both learned the hard way:

- **A `claude-code/<version>` User-Agent is required.** Without it the endpoint drops you into an aggressively rate-limited bucket and returns persistent 429s. The version is read from your local install.
- **Polling never goes below 180 seconds.** That's the observed safe floor. On a 429 the interval doubles up to 30 minutes, then snaps back once it recovers. The UI still ticks every second because reset countdowns are computed locally from `resets_at` — no network involved.

## Caveats

- The usage endpoint is **undocumented**. It can change shape or disappear without notice. The parser prefers the generic `limits` array and falls back to the older per-window fields, but a large enough change will break it.
- First launch may show a keychain prompt. It's macOS asking whether `/usr/bin/security` may read the Claude Code credential — click **Always Allow** and it won't ask again.
- If the icon reads `· Not signed in`, run `claude` in a terminal and sign in, then hit **Refresh now**.
- Menu bar crowded? ⌘-drag the icon to reposition it.

## Uninstall

```bash
pkill -f MacOS/ClaudeUsageBar
rm -rf ~/Applications/"Claude Usage.app"
rm -f ~/Library/LaunchAgents/com.local.claudeusagebar.plist
```

## Layout

- [`ClaudeUsageBar.swift`](ClaudeUsageBar.swift) — the whole app: fetching, parsing, and AppKit views, no dependencies
- [`build.sh`](build.sh) — compile, bundle, sign

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Anthropic.
