# Project Brief

## Repository

* Local path: `~/Codes/swift/QuotasWatcher`
* GitHub repository: `ezraluuu-lhk/QuotasWatcher`

## Desired Outcome

QuotasWatcher currently monitors Codex quota usage only.

Extend it to monitor Kimi Code quota usage alongside Codex, while preserving all existing Codex behavior.

The result should treat Codex and Kimi as separate quota providers with independent fetching, state, errors, and presentation.

## Menu Bar Popover

Add a tab or segmented control to the existing popover with two options:

* Codex
* Kimi

The Codex tab should preserve the current Codex quota presentation and behavior.

The Kimi tab should display Kimi Code quota information using the same overall visual language where the available Kimi data maps naturally to the existing quota rows.

Switching tabs should:

* happen without closing the popover;
* immediately display the selected provider’s latest known data;
* preserve each provider’s existing data while refreshes are running;
* clearly show which provider is selected;
* preserve the selected tab while the application remains running.

The two providers must maintain independent loading and error states. A Kimi refresh failure must not remove valid Codex data, and a Codex failure must not remove valid Kimi data.

## Menu Bar Status Item

Update the status-item behavior so that the displayed provider and percentage are unambiguous.

The implementation plan should choose a compact behavior consistent with the existing design. Prefer displaying the currently selected provider’s primary remaining quota rather than placing both full values in the menu bar.

Codex should remain the default selected provider unless there is a strong usability reason to change this.

## Touch Bar

Display Codex and Kimi quota information simultaneously in the Touch Bar because sufficient horizontal space is available.

The Touch Bar must:

* clearly label Codex and Kimi values;
* keep the two providers visually distinct;
* update each provider independently;
* preserve valid data for one provider when the other provider fails;
* remain readable within the available Touch Bar width.

The implementation plan should determine which quota window or compact summary provides the most useful simultaneous display.

## Kimi Quota Source

Before implementation, investigate how the locally authenticated Kimi Code installation exposes quota information.

Prefer, in order:

1. a documented local command or machine-readable interface;
2. a stable authenticated local API already used by Kimi Code;
3. another official and maintainable interface.

Do not:

* scrape the Kimi website;
* require the user to copy browser cookies;
* log authentication credentials or tokens;
* invent quota values from request counts;
* parse unstable terminal formatting without documenting and testing the limitation.

If Kimi does not currently expose a sufficiently stable machine-readable quota interface, document the limitation and propose the safest workable approach before proceeding with the full implementation.

## Architecture

Refactor the current Codex-only design into a provider-aware design.

Provider-specific responsibilities should be isolated, including:

* binary or service discovery;
* authentication assumptions;
* quota fetching;
* response parsing;
* provider-specific errors.

Shared responsibilities should remain reusable, including:

* quota presentation models where appropriate;
* refresh-state behavior;
* menu bar rendering;
* Touch Bar rendering;
* logging;
* localization;
* testing utilities.

Avoid adding Kimi support as scattered conditional branches throughout `AppDelegate` or the view controllers.

The architecture should make adding another quota provider later possible without another major UI and state-management rewrite.

## Refresh Behavior

Continue the existing periodic refresh behavior.

A manual refresh should refresh both providers.

Each provider should:

* refresh independently;
* retain its previous valid snapshot until a new valid snapshot is available;
* expose its own loading and error state;
* log failures without leaking credentials;
* not prevent the other provider from completing its refresh.

## Existing Behavior That Must Be Preserved

The following Codex functionality must continue working:

* five-hour quota display;
* weekly quota display;
* weekly fallback when the five-hour quota is unavailable;
* reset-time display;
* available reset-credit display;
* periodic refresh;
* manual refresh;
* error copying;
* log opening;
* existing Bark notifications;
* English and Simplified Chinese localization;
* menu bar and Touch Bar support.

## Notifications

Existing Codex Bark notifications must continue working without regression.

Kimi-specific Bark notifications are out of scope for this first implementation unless they can be supported cleanly using reliable reset timestamps exposed by the official Kimi quota source.

## Testing and Verification

Add or update tests for:

* Kimi quota-response parsing;
* provider-specific refresh state;
* one provider succeeding while the other fails;
* retention of previous valid data during refresh;
* tab-selection behavior where practical;
* menu bar summary selection;
* existing Codex parsing and reset detection;
* localization-key consistency.

Required verification commands:

```bash
swift test
Scripts/check-localizations.sh
swift build -c release
Scripts/package-app.sh
```

The packaged application should then be opened and manually checked for:

* Codex tab rendering;
* Kimi tab rendering;
* tab switching;
* independent error states;
* simultaneous Touch Bar display;
* manual refresh;
* no regression in existing Codex behavior.

## Out of Scope

* Claude Code support;
* redesigning the entire application;
* changing the existing Bark service;
* web scraping;
* storing Kimi credentials inside QuotasWatcher;
* adding unrelated settings or providers;
* publishing or releasing the application automatically.

## Definition of Done

The work is complete when:

1. QuotasWatcher retrieves and displays both Codex and Kimi quota information through maintainable provider-specific integrations.
2. The popover provides working Codex and Kimi tabs.
3. The Touch Bar displays both providers simultaneously.
4. Provider refresh and error states are independent.
5. Existing Codex behavior and notifications continue working.
6. Tests, localization checks, release build, and packaging all succeed.
7. No authentication secrets appear in source code, logs, tests, or committed files.

## User-approved follow-up — fullscreen auto-hidden menu bar

On 2026-07-21, the user explicitly requested that the popover anchoring defect be fixed:

- With the macOS menu bar visible, the status-item popover is positioned correctly.
- In a fullscreen Space with the menu bar configured to auto-hide, the open popover remains at the status item's former position after the menu bar hides and its top portion becomes clipped.

The packaged application must keep an already-open popover fully visible and correctly associated with the QuotasWatcher status item as the fullscreen menu bar hides and reappears. The repair must preserve transient close behavior, selected-provider state, tab switching without close, dynamic content sizing, status-item actions, and existing Codex/Kimi behavior. Use supported AppKit APIs; do not use private APIs or a continuous polling loop.
