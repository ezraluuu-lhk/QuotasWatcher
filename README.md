# QuotasWatch

QuotasWatch is a small macOS menu bar app for Codex quota visibility. It uses Swift/AppKit and reads quota data from the local Codex app-server instead of scraping web pages.

## Build

```bash
swift test
swift build -c release
Scripts/package-app.sh
```

The packaged app is written to:

```text
dist/QuotasWatch.app
```

Open it from Finder or run:

```bash
open dist/QuotasWatch.app
```

## Requirements

- macOS 13 or newer.
- Codex CLI/app-server installed and authenticated.
- QuotasWatch starts Codex with:

```bash
codex app-server --listen stdio://
```

Binary lookup order:

1. `/Applications/Codex.app/Contents/Resources/codex`
2. `/usr/local/bin/codex`
3. `/opt/homebrew/bin/codex`
4. `codex` from `PATH`

## Behavior

The menu bar item shows the 5-hour quota remaining percentage. The popover shows two segmented battery rows:

- `5小时`
- `周限额`

Each row displays remaining percentage and reset time. Remaining quota is calculated as `100 - usedPercent`. Refreshes keep the previous data visible until a new valid response arrives. The app refreshes every 5 minutes and also provides manual refresh plus quit actions.

## Troubleshooting

- `Codex binary was not found.`: install Codex or make sure `codex` is available in one of the lookup paths above.
- `Not initialized`: the app-server requires JSON-RPC `initialize` before `account/rateLimits/read`; QuotasWatch sends this automatically. If this appears, update Codex and restart the app.
- `failed to fetch codex rate limits`: Codex app-server could not reach the ChatGPT backend or is not authenticated. Check network access and run Codex once interactively to confirm login.
- No Touch Bar content: Touch Bar support depends on hardware and macOS Touch Bar availability.
