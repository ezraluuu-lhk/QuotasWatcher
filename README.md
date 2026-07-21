# QuotasWatcher

[简体中文](README.zh-Hans.md)

A tiny macOS utility for watching your Codex and Kimi Code quotas from the Touch Bar or menu bar.

If you are still using a MacBook with a Touch Bar, QuotasWatcher shows your remaining Codex and Kimi quota there. On Macs without a Touch Bar, it falls back to the menu bar.

Claude Code support: no. I do not like Anthropic, so if you need that version, go vibe it yourself.

## Screenshots

![QuotasWatcher menu bar popover](docs/assets/menu-en.png)

![QuotasWatcher Touch Bar quota display](docs/assets/touchbar-en.png)

## Install from Release

1. Download the latest `QuotasWatcher-*-macos.zip` from [GitHub Releases](https://github.com/ezraluuu-lhk/QuotasWatcher/releases).
2. Unzip it and move `QuotasWatcher.app` to `/Applications` if you want.
3. Open `QuotasWatcher.app`, then look for `Codex --%`, `Codex NN%`, `Kimi --%`, or `Kimi NN%` in the macOS menu bar, depending on the selected provider.

The app is not signed or notarized yet. If macOS blocks the first launch, right-click `QuotasWatcher.app`, choose `Open`, then confirm once.

## Build

```bash
swift test
Scripts/check-localizations.sh
swift build -c release
Scripts/package-app.sh
```

The packaged app is written to:

```text
dist/QuotasWatcher.app
```

Open the `.app` bundle itself from Finder, or run:

```bash
open dist/QuotasWatcher.app
```

Do not open `dist/QuotasWatcher.app/Contents/MacOS/QuotasWatcher` directly. That is the internal Unix executable; Finder will launch Terminal and show a line like `.../Contents/MacOS/QuotasWatcher ; exit;`.

## Requirements

- macOS 13 or newer.
- Codex CLI/app-server installed and authenticated, **or** Kimi Code installed and authenticated, **or both**.
- QuotasWatcher starts Codex with:

```bash
codex app-server --listen stdio://
```

Codex binary lookup order:

1. `/Applications/Codex.app/Contents/Resources/codex`
2. `/usr/local/bin/codex`
3. `/opt/homebrew/bin/codex`
4. `codex` from `PATH`

Kimi Code binary lookup order:

1. `KIMI_CODE_HOME/bin/kimi` (or `~/.kimi-code/bin/kimi` by default)
2. `/usr/local/bin/kimi`
3. `/opt/homebrew/bin/kimi`
4. `kimi` from `PATH`

Kimi authentication is read from the existing Kimi Code credential store (`~/.kimi-code/credentials`). QuotasWatcher does not store a separate copy and does not log tokens or raw credential JSON.

## Behavior

The menu bar item shows the selected provider's 5-hour quota remaining percentage, with the provider name (`Codex` or `Kimi`) included so the value is unambiguous. If the selected provider does not return a 5-hour window, it falls back to weekly usage, marks the menu bar value with `W`, and shows an explanatory banner in the popover.

The popover has a `Codex`/`Kimi` segmented selector at the top. Switching tabs updates the popover, menu bar, and status immediately without closing the popover. The selected tab persists while the app is running. Each provider keeps its own loading state, last valid snapshot, and error; a failure for one provider does not remove the other provider's data.

The popover shows two segmented battery rows for the selected provider:

- `5h`
- `Weekly`

Each row displays remaining percentage and reset time. Codex reset credits and the Bark settings button are shown only when Codex is selected. Remaining quota is calculated as `100 - usedPercent` for Codex and from `limit - used`/`limit - remaining` for Kimi. Refreshes keep the previous data visible until a new valid response arrives. The app refreshes both providers every 5 minutes and refreshes both on manual refresh.

After launch, look for `Codex --%`/`Codex NN%` or `Kimi --%`/`Kimi NN%` in the macOS menu bar near the clock. Click it to open the quota popover. Right-click it for refresh, copy error, open log, Bark settings, and quit actions.

Touch Bar content is contextual: click the menu bar item to open the QuotasWatcher popover and make the app active. When macOS exposes a physical Touch Bar for the active app, it shows compact `Codex` and `Kimi` summaries simultaneously, each updating independently.

The popover and right-click menu include `Copy Error` and `Open Log` actions for troubleshooting. Logs are written to:

```text
~/Library/Application Support/QuotasWatcher/QuotasWatcher.log
```

## Bark Notifications

QuotasWatcher can send quota-reset notifications to an iPhone through [Bark](https://github.com/Finb/Bark). Open `Codex Bark…` from the popover or right-click menu, enter the device key or its `https://api.day.app/<key>/` URL, and use `Test Connection` to verify delivery.

Notification types can be enabled independently:

- Scheduled 5-hour resets
- Scheduled weekly resets
- Other/free resets, detected when remaining quota rises by at least 10 percentage points and the reset date advances before the scheduled reset
- Reset-bank increases, detected when the number of available banked resets rises

The Bark key is stored locally in macOS app preferences. QuotasWatcher never writes the key or complete push URL to its log. Scheduled-reset comparisons use a 30-minute observation window. Strong other/free-reset evidence remains eligible across gaps up to 6 hours, which covers ordinary sleep and network interruptions without reporting resets after a long shutdown. Reset-bank increases use the explicit bank count and can still be reported after a longer observation gap.

## Localization

QuotasWatcher uses native macOS `.lproj` localization files:

```text
Sources/QuotasWatcher/Resources/en.lproj/Localizable.strings
Sources/QuotasWatcher/Resources/zh-Hans.lproj/Localizable.strings
```

Run this before opening a pull request:

```bash
Scripts/check-localizations.sh
```

The packaging script copies these `.lproj` directories into `dist/QuotasWatcher.app/Contents/Resources`.

## License

MIT. See [LICENSE](LICENSE).

## Troubleshooting

- `Codex binary was not found.`: install Codex or make sure `codex` is available in one of the lookup paths above.
- `Kimi Code binary was not found.`: install Kimi Code or make sure `kimi` is available in one of the lookup paths above.
- `Kimi credentials were not found. Run \`kimi login\` to authenticate.`: Kimi Code must be logged in at least once so its credential file exists under `~/.kimi-code/credentials`.
- `Kimi session has expired or been revoked. Run \`kimi login\` to authenticate again.`: the stored refresh token is no longer valid; re-authenticate with Kimi Code.
- `Not initialized`: the app-server requires JSON-RPC `initialize` before `account/rateLimits/read`; QuotasWatcher sends this automatically. If this appears, update Codex and restart the app.
- `failed to fetch codex rate limits`: Codex app-server could not reach the ChatGPT backend or is not authenticated. Check network access and run Codex once interactively to confirm login.
- No Touch Bar content: click the QuotasWatcher menu bar item first so its popover is active. Touch Bar support also depends on hardware and macOS Touch Bar availability; Macs without a physical Touch Bar will not show it.
