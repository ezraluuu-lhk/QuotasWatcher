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

Open the `.app` bundle itself from Finder, or run:

```bash
open dist/QuotasWatch.app
```

Do not open `dist/QuotasWatch.app/Contents/MacOS/QuotasWatch` directly. That is the internal Unix executable; Finder will launch Terminal and show a line like `.../Contents/MacOS/QuotasWatch ; exit;`.

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

After launch, look for `Codex --%` or `Codex NN%` in the macOS menu bar near the clock. Click it to open the quota popover. Right-click it for refresh and quit actions.

Touch Bar content is contextual: click the menu bar item to open the QuotasWatch popover and make the app active. The Touch Bar mirrors the same two quota rows when macOS exposes a physical Touch Bar for the active app.

The popover and right-click menu include `复制错误` and `复制日志` actions for troubleshooting. Logs are written to:

```text
~/Library/Application Support/QuotasWatch/QuotasWatch.log
```

## Troubleshooting

- `Codex binary was not found.`: install Codex or make sure `codex` is available in one of the lookup paths above.
- `Not initialized`: the app-server requires JSON-RPC `initialize` before `account/rateLimits/read`; QuotasWatch sends this automatically. If this appears, update Codex and restart the app.
- `failed to fetch codex rate limits`: Codex app-server could not reach the ChatGPT backend or is not authenticated. Check network access and run Codex once interactively to confirm login.
- No Touch Bar content: click the QuotasWatch menu bar item first so its popover is active. Touch Bar support also depends on hardware and macOS Touch Bar availability; Macs without a physical Touch Bar will not show it.
