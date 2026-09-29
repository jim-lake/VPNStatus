# AGENTS.md

Guidance for AI agents (and humans) working in the VPNStatus codebase. This
document explains how the existing code is structured, how the pieces fit
together, and the conventions to follow when making changes.

## What this project is

VPNStatus is a macOS menu-bar application that replicates parts of the built-in
macOS VPN status menu. It lets the user list VPN services, connect/disconnect,
and optionally auto-connect. The repository ships **one app** plus its test
bundles:

| Target        | Type                | Purpose |
|---------------|---------------------|---------|
| `VPNStatus`   | Menu bar app (`LSUIElement`) | The one and only app. Lives in the macOS menu bar. |
| `VPNStatusTests` | Unit test bundle | XCTest target hosted on `VPNStatus`: `GitHubRelease` version parsing + `ACMenuReconciler` behavior + reconnect backoff + Min/Max Reconnect preferences. |
| `VPNStatusUITests` | UI test bundle | XCUITest target that drives the real `VPNStatus` menu-bar app end to end (status item, menu contents, connect/disconnect, quit). |

> **`vpnutil` is no longer part of this repo.** The old in-tree `vpnutil` CLI
> target and its `VPNUtil` dylib have been removed. `vpnutil` still exists as an
> independent tool — install it from Homebrew
> (`brew install timac/vpnstatus/vpnutil`) and use it for command-line checks
> and independent verification of VPN state (see "How to ACTUALLY check whether
> the machine has a VPN").
>
> **The old windowed `VPNApp` variant has also been removed.** `VPNStatus` is the
> only app; all shared VPN logic lives in `Common/`.

## Language & platform

- **Languages:** Objective-C (core + most UI) and Swift (update checker + its
  SwiftUI view). The two interoperate through the generated
  `VPNStatus-Swift.h` header and `VPNStatus-Bridging-Header.h`.
- **UI:** AppKit/Cocoa with XIB files (`*.lproj/*.xib`). The update dialog is
  SwiftUI hosted inside an `NSWindowController`.
- **Deployment target:** macOS 12.0. **Swift version:** 5.0.
- **Frameworks:** `NetworkExtension`, `SystemConfiguration`, `CoreLocation`,
  `CoreWLAN`, `Cocoa`/`AppKit`, `SwiftUI`.

## How to build and test

This is a plain Xcode project (`VPN.xcodeproj`) with no package manager. A
`Makefile` wraps the common `xcodebuild` invocations (with unsigned-build flags
baked in) and the code formatter; run `make help` to list targets. You can use
`make`, `xcodebuild`, or Xcode directly.

```bash
# Via the Makefile (preferred — handles code-signing flags for you):
make build        # build the menu bar app (VPNStatus)
make test         # run the unit tests
make format       # clang-format all Obj-C sources in place
make format-check # verify formatting (CI-friendly, non-mutating)
make run          # build + launch the app, leaving it running

# Or drive xcodebuild directly:
# Build the menu bar app
xcodebuild -project VPN.xcodeproj -scheme VPNStatus -configuration Debug build

# Run the unit tests. The VPNStatusTests bundle is hosted on the VPNStatus app
# (TEST_HOST = VPNStatus) and runs under the VPNStatus scheme:
xcodebuild -project VPN.xcodeproj -scheme VPNStatus -destination 'platform=macOS' test
```

The `VPNStatusTests` unit bundle covers `GitHubRelease` version comparison
(Swift), the menu reconciler (`ACMenuReconcilerTests.m`, Obj-C), the reconnect
backoff (`ACConnectionManagerBackoffTests.m`), and the Min/Max Reconnect
preferences (`ACPreferencesReconnectTests.m`). The reconciler's `.m` is compiled
into both the `VPNStatus` app target and the test target so the tests link its
symbols directly; the backoff/preferences tests instead resolve their symbols
against the host app (`BUNDLE_LOADER`) and reach `ACConnectionManager`'s internal
backoff state through `Common/ACConnectionManager_Internal.h`. The test target's
`HEADER_SEARCH_PATHS` includes `$(SRCROOT)/Common`.

Shared schemes live in `VPN.xcodeproj/xcshareddata/xcschemes/`
(`VPNStatus.xcscheme`, `VPNStatusUITests.xcscheme`); the `VPNStatus` scheme's
test action runs the `VPNStatusTests` bundle. After changing code, prefer
building the affected scheme before presenting results.

### Code signing: build unsigned

The app runs fine **unsigned**. If you hit `No signing certificate "Mac
Development" found`, that is *not* a real problem — disable signing rather than
chasing certificates:

```bash
CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Append those flags to any `xcodebuild` invocation (unit tests, UI tests). Do
not assume test failures are signing-related.

### UI tests (`VPNStatusUITests`) — real end-to-end

`VPNStatusUITests/VPNStatusMenuUITests.swift` drives the **real** menu-bar app:
it opens the live status-item menu, reads the real rows, activates real menu
actions, and verifies the real effect (VPN connect/disconnect, app quit).

```bash
# UI tests — ad-hoc sign the runner (CODE_SIGNING_ALLOWED=YES).
xcodebuild -project VPN.xcodeproj -scheme VPNStatusUITests -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES test
```

> **Why `CODE_SIGNING_ALLOWED=YES` for the UI scheme (unlike the app/unit
> builds):** the stock Xcode `XCTRunner.app` template ships **unsigned**. With
> `CODE_SIGNING_ALLOWED=NO`, xcodebuild leaves it unsigned and Gatekeeper rejects
> the runner at launch with a "the application is damaged and can't be run"
> dialog, so the UI tests never start. Allowing signing lets xcodebuild ad-hoc
> sign the runner (`CODE_SIGN_IDENTITY="-"`), which launches cleanly. The app and
> unit tests still build fine with `CODE_SIGNING_ALLOWED=NO`. Wrap UI-test runs in
> a `timeout` so a wedged run can't block indefinitely.

> **Rule for this repo's docs:** never add a line to any Markdown file (this file,
> `AUTO_CONNECT.md`, or any other) claiming that tests cannot be run — for any
> reason (SSH, "no GUI/Aqua session", session type, etc.). Tests can always be
> run here. Do not reintroduce such claims.

The toggle test (`testClickingServiceTogglesConnection`) verifies the real VPN
state by shelling out to `vpnutil`. `vpnutil` is **not** built from this repo any
more — install it from Homebrew (`brew install timac/vpnstatus/vpnutil`). The
test looks for it at `/opt/homebrew/bin/vpnutil` or `/usr/local/bin/vpnutil`; if
it is absent the toggle test is skipped (the other four still run).

The five tests:

- `testStatusItemAppears` — the `NSStatusItem` shows in the menu bar. It carries
  `accessibilityIdentifier = "VPNStatusItem"` (set on `statusItem.button` in
  `AppDelegate`).
- `testMenuShowsStaticItems` — opening the menu shows `Settings…`
  (`static.settings`) and `Quit VPNStatus` (`static.quit`).
- `testMenuShowsAServiceActionRow` — the real VPN renders a
  `Connect/Disconnect <name>` row plus a matching `service.name.<UUID>` label.
- `testClickingServiceTogglesConnection` — activates the service row and confirms
  via `vpnutil` that the real VPN flips state, then flips back
  (Connected → Disconnected → Connected).
- `testQuitTerminatesApp` — activates Quit and confirms the app terminates.

How it works (and why it is built this way — these are hard-won macOS
constraints, don't "simplify" them away):

1. **Reading a status-item menu works; clicking its rows does not.** After
   `statusItem().click()` opens the menu, XCUITest can read the rows' stable
   identifiers/titles. But the popped-up rows are non-hittable (zero-size frames)
   — `XCUIElement.click()`/`hover()` on a row hangs ~60s on a "menu open"
   notification that never fires, coordinate clicks miss, and `typeKey` doesn't
   route to the tracking menu.
2. **Activating rows uses a UI-test-only hook.** When launched with
   `UITEST_AUTOMATION=1` (set via `launchEnvironment`), `AppDelegate` observes an
   `NSDistributedNotification` (`org.timac.VPNStatus.uitest.activate`, object =
   row identifier) and calls `-[NSMenu performActionForItemAtIndex:]`, which
   dispatches the row's real target/action exactly as a click would
   (`connectService:`/`disconnectService:`/`doQuit:`). The hook is inert unless
   the env var is set. The menu *contents* the tests assert on are read from the
   live menu by XCUITest; only the *activation* goes through the hook.
3. **A status-item menu is only visible to XCUITest on the first open per
   session.** After one open/close cycle, `app.statusItems` returns empty for the
   rest of the run (the app still runs fine — `app.state == .runningForeground`).
   So each test opens the menu at most once; the toggle test reads the menu once
   for the UUID/name, then verifies the *effect* via `vpnutil` instead of
   re-opening.
4. **Queries scope to the status item's own menu**, not the global
   `app.menuItems`: clicking the status item also makes AppKit synthesize a
   standard app menu bar that contains a *second* `Settings…`/`Quit VPNStatus`.
5. **Opening the menu is retried** (`app.activate()` + click) because a status
   click occasionally registers without opening the menu.

Supporting production changes for testability (in `VPNStatus/AppDelegate.m`):
stable `identifier`s on the static `Settings…`/`Quit` items (`static.settings` /
`static.quit`), and the `UITEST_AUTOMATION` distributed-notification hook.

### How to ACTUALLY check whether the machine has a VPN (READ THIS FIRST)

**Do not use `scutil --nc list`, `scutil --nc status`, or
`networksetup -listallnetworkservices` to decide whether a VPN exists or what
its state is. They cannot see the VPNs this project manages.** The VPNs here are
**NetworkExtension (`NEConfiguration`) VPNs** — IKEv2 personal VPNs and VPN
clients that install a NE configuration. macOS's built-in CLI tooling does
**not** enumerate these:

- `scutil --nc list` → prints only the header line with **no services**, even
  when a VPN is configured and actively connected. `scutil --nc status "<name>"`
  answers `No Service`. This is a long-standing, still-open Apple limitation:
  `scutil` does not support IKEv2 / NE-based VPN services (Apple bug
  rdar://41950946, filed by this project's original author — see
  <https://blog.timac.org/2018/0719-vpnstatus/> and
  <https://blog.timac.org/2018/0717-macos-vpn-architecture/>). Empty output is
  **not** "no VPN"; the tool is simply blind to these VPNs.
- `networksetup -listallnetworkservices` → same blind spot; no VPN entries.
- `ifconfig | grep utun` → shows `utunN` interfaces, but these are created by
  many things (other VPNs, Handoff/AWDL, Back to My Mac, etc.). You cannot map a
  `utunN` interface to a named VPN or a real connection state from this. Useless
  for the question "is VPN X connected?".

There is **no** stock macOS command that reports these VPNs — that gap is the
entire reason this project reaches into the private `NEConfigurationManager` /
`ne_session_get_status` APIs (see `ACDefines.h`). The correct sources of truth
are things that run that same code path:

1. **`vpnutil` (recommended for independent verification).** `vpnutil` is a
   small CLI over the exact same `NEConfiguration` / `ne_session_get_status`
   path. **It is no longer part of this repo** — install it independently from
   Homebrew and use it to verify VPN state from the command line:

   ```bash
   brew tap timac/vpnstatus
   brew install timac/vpnstatus/vpnutil

   vpnutil list             # JSON of {name, status} for every NE VPN
   vpnutil status <name>    # one line: "<name> <Status>"
   ```

   On the current dev machine `vpnutil list` reports the real VPN
   `ares-staging` = `Connected` — the VPN that `scutil`/`networksetup` claim
   does not exist. This is the go-to way to check real VPN state and to
   independently confirm what the app/tests observe.

2. **The `VPNStatus` app itself.** The running app's menu shows the per-service
   row with a checkmark and a `Connect`/`Disconnect <name>` title, and the
   `UITEST_AUTOMATION` distributed-notification hook (see the UI tests section)
   reports the real `ne_session` status programmatically. This is the source of
   truth the UI tests assert against.

If you see "empty" output from `scutil`/`networksetup` and are tempted to
conclude "this machine has no VPN" — **stop**. You are using a tool that
structurally cannot see NE/IKEv2 VPNs. Use brew's `vpnutil` (or ask the app)
instead.

### Testing pitfalls (mistakes made while getting UI tests working)

Recorded so the next agent does not repeat them:

- **The signing error is a red herring.** The build fails with `No signing
  certificate "Mac Development"` unless you pass the `CODE_SIGNING_*` flags above.
  The app works unsigned; do not spend time on certificates/provisioning.
- **Do not fiddle with TCC / Accessibility to "fix" it.** Resetting or trying to
  add `kTCCServiceAccessibility` grants for the xctrunner (`tccutil reset`,
  editing `TCC.db`) does not help and actively makes things worse: it triggers
  repeated permission re-prompts and can leave the automation subsystem wedged so
  that *every* run re-times-out. `TCC.db` is SIP-protected (read-only to direct
  writes) anyway. The transient, ad-hoc-signed runner (`com.apple.XCTRunner`)
  cannot hold a stable grant, so this path is a dead end. Leave TCC alone.
- **Don't run xcodebuild as root or with a custom `-derivedDataPath` under
  `sudo`.** Doing so creates root-owned build artifacts (e.g. under `/tmp`) that
  you then can't clean up without `sudo`. Run as the normal user.
- **The raw Accessibility API (`AXUIElementPerformAction`, `kAXPressAction`)
  needs the caller trusted for Accessibility**, which the transient UI-test
  runner is not (`AXIsProcessTrusted()` is `false`; the app's AX element returns
  no children). That is why activation goes through the in-app
  `UITEST_AUTOMATION` hook instead.
- **`.click()`/`.hover()` on a status-menu row hangs the test for ~60s** on the
  menu-open wait, and coordinate/keyboard approaches don't land on the rows.
  Don't try to make XCUITest click the popped-up status menu directly.
- **After the first menu open, `app.statusItems` goes empty.** Don't write a poll
  loop that re-opens the status menu to observe state; verify the effect another
  way (the toggle test uses `vpnutil`).

## Architecture overview

The dependency flow is roughly:

```
UI layer (AppDelegate / PreferencesUI)
        │  reads/writes
        ▼
ACPreferences  (NSUserDefaults wrapper, singleton)
        ▲
        │ used by
ACConnectionManager  (auto-connect policy + timer, singleton)
        │  operates on
        ▼
ACNEServicesManager  (owns the list of services, singleton)
        │  contains
        ▼
ACNEService  (one VPN configuration + its ne_session_t)
        │  wraps private
        ▼
ne_session_* C APIs + NEConfigurationManager (declared in ACDefines.h)
```

Communication back up to the UI is done with `NSNotificationCenter`
notifications, not delegates or callbacks (see "Notifications" below).

## Directory / file guide

### `Common/` — shared core (used by the app and its tests)

- **`ACDefines.h`** — The linchpin of the whole app. Declares the **private
  Apple APIs** that macOS does not expose publicly:
  - `ne_session_*` C functions from `libsystem_networkextension.dylib`
    (`create`/`start`/`stop`/`cancel`/`get_status`/`set_event_handler`).
  - `SCNetworkConnectionGetStatusFromNEStatus` from `SystemConfiguration`.
  - Private classes `NEVPN`, `NEConfiguration`, `NEConfigurationManager`.
  - The `kSessionStateChangedNotification` name.
  These are re-declared from Apple's open-source `configd` headers. If Apple
  changes these private symbols in a future macOS, this file is where breakage
  will surface.

- **`ACNEService.{h,m}`** — Models a single VPN service. Wraps one
  `NEConfiguration` and its `ne_session_t`. Responsibilities:
  - Creates the session from the configuration's UUID.
  - Registers an event handler that calls `refreshSession` on change.
  - `refreshSession` queries status on `neServiceQueue`, then hops to the main
    queue to store `sessionStatus` and post `kSessionStateChangedNotification`.
  - Exposes `name`, `serverAddress`, `protocol` (IKEv2/IPSec/L2TP/…), `state`,
    `connect`, `disconnect`.

- **`ACNEServicesManager.{h,m}`** — Singleton that owns
  `NSMutableArray<ACNEService*> *neServices` and the serial
  `neServiceQueue`. `loadConfigurationsWithHandler:` calls the private
  `NEConfigurationManager` to load all configurations, filters them (see
  filtering below), builds `ACNEService` objects, sorts by name, and refreshes
  their state.

- **`ACConnectionManager.{h,m}`** — Singleton holding the **auto-connect
  policy**:
  - A repeating `NSTimer` (`alwaysAutoConnectTimer`) fires every
    `alwaysConnectedRetryDelay` seconds (default 120s) and reconnects any
    service marked "always auto connect".
  - Pause/resume support (`pauseAutoConnect:`, `resumeAutoConnect`,
    `isAutoConnectPaused`). `NSIntegerMax` duration means "pause indefinitely".
  - `shouldPreventAutoConnectOnCurrentSSID` checks the current Wi-Fi SSID (via
    `CWWiFiClient`/`CWInterface`) against the ignored-SSID list.
  - `connect/disconnectAllAutoConnectedServices`, `toggleConnectionForService:`.

- **`ACPreferences.{h,m}`** — Singleton wrapper over
  `NSUserDefaults` (domain `org.timac.VPNStatus`). Stores:
  - `Services` array of `{Identifier, AlwaysConnected}` dicts.
  - `IgnoredSSIDs` / `IgnoredVPNs` (comma-joined strings).
  - `AlwaysConnectedRetryDelay` (clamped to 1–240s on write).
  - `DisabledCheckForUpdatesAutomatically`, `SingleAutoConnect`,
    `MenuBarImageType`.
  - Also owns menu-bar image lookup (`menuBarImageForState:andType:`), choosing
    between bundled template images and SF Symbols ("Cloud" style).
  - Setters post `kACConfigurationDidChange` / `kACMenuBarImageDidChange`.

- **`ACLocationManager.{h,m}`** — Singleton around `CLLocationManager`. On
  macOS 14+ reading the Wi-Fi SSID requires Location Services authorization.
  Exposes `authorizationStatus`, `requestAlwaysAuthorizationIfNeeded`, and
  posts `kACLocationManagerAuthorizationDidChange` when authorization changes.

- **`ACMenuReconciler.{h,m}`** — UI-only helper (depends on `Cocoa`, nothing
  else) that updates a region of an `NSMenu` **in place** from a list of
  `ACMenuRowDescriptor` value objects, instead of rebuilding the menu. Matches
  existing items to descriptors by a stable `key` (set as `NSMenuItem.identifier`),
  reusing/moving surviving items and only inserting/removing rows that actually
  changed. Deliberately decoupled from `ACNEService`/singletons so it is
  unit-testable (`ACMenuReconcilerTests`); `AppDelegate` builds descriptors from
  its services and delegates the per-service action rows to it, so the tested
  code is the code that runs.

### `VPNStatus/` — the primary menu bar app

- **`AppDelegate.{h,m}`** — The heart of the menu bar app.
  - Builds a **persistent** `NSMenu` skeleton once at launch
    (`buildInitialMenu`) and thereafter updates it **in place** via
    `refreshMenu` → `reconcile*` methods. The menu is never rebuilt wholesale
    and `statusItem.menu` is never reassigned, so an open menu isn't disturbed
    (no flicker, no lost highlight). The menu is divided into fixed sections
    delimited by hidden separator "anchor" items (identified by
    `NSMenuItem.identifier`): a top **"Disconnect All"** row (disabled when
    nothing is connected; its title shows the connected VPN's name when exactly
    one is connected, otherwise a connection count), per-service
    connect/disconnect rows, and a static Settings/Quit block built once. Each
    per-service connect/disconnect row shows a **checkmark** while that service
    is connected. There is no pause section, no per-service info block, and no
    Location Services prompt in the menu.
  - **Auto-connect is driven by the menu actions themselves.** Manually
    connecting a service (`connectService:`) marks it always-auto-connect;
    manually disconnecting (`disconnectService:`) clears its always-auto-connect
    flag so the timer won't immediately reconnect it. "Disconnect All"
    (`disconnectAll:`) disconnects every connected service and clears their
    auto-connect flags. There is no "Always auto connect" toggle row and no
    pause controls.
  - Reconciliation diffs by **stable identity**: per-service items carry
    `identifier` = a section prefix + the service's configuration UUID, and
    `representedObject` = the UUID. Surviving services keep their existing
    `NSMenuItem`; only added/removed services cause insert/remove, and item
    setters (`title`/`action`/`state`/`enabled`) are only touched when the value
    actually changed.
  - `menuWillOpen:` (NSMenuDelegate) triggers an asynchronous
    `reloadConfigurationsAndApplyAutoConnect:NO` so VPNs added/removed in the
    system UI are picked up on open, without blocking the menu and without
    re-applying the auto-connect policy.
  - `updateStatusItemIcon` picks the On/Off icon based on whether any service
    is connected.
  - Registers for the session/config/menu-bar-image notifications and calls
    `reloadConfigurations` / `refreshMenu` accordingly.
  - Menu-item actions resolve the target service by **UUID**
    (`serviceForMenuItem:` reads `representedObject`), not by list position.
  - **UI-test hooks** (see "How to build and test"): the static `Settings…`/
    `Quit VPNStatus` items carry stable identifiers (`static.settings` /
    `static.quit`), and when launched with `UITEST_AUTOMATION=1` the delegate
    observes an `NSDistributedNotification` and activates a menu row by its
    identifier via `-[NSMenu performActionForItemAtIndex:]`. Both are inert in
    normal use; they exist because XCUITest can read but not click a popped-up
    status-item menu.
- **`PreferencesUI/`** — AppKit preferences window:
  - `ACPreferencesWindowController` — toolbar-based container that swaps
    between child view controllers with a resize animation.
  - `ACPreferencesGeneralViewController` — retry delay, auto-update toggle,
    single-auto-connect toggle, menu-bar image style, manual "check for
    updates".
  - `ACPreferencesIgnoredViewController` — two table views for ignored SSIDs
    and ignored VPNs; validates each entry as a regular expression and shows
    invalid ones in red. (Note the mismatch called out under "Gotchas".)
  - `ACPreferencesAboutViewController`, `NSBundle+ACAppInfo` (app metadata),
    `ACPreferencesWindowControllerProtocol` (requires `identifier`/`title`).
- **`CheckForUpdate/`** — Swift update checker:
  - `UpdateManager` (`@objc`, singleton `shared`) — fetches
    `https://api.github.com/repos/Timac/VPNStatus/releases`, decodes JSON,
    finds the newest non-draft/non-prerelease, compares to the running version,
    and shows the update window (or an "up to date" alert). Supports a
    per-version "skip" preference (`SkipVersion`).
  - `GitHubRelease` — `Decodable`+`Comparable` struct doing semantic-ish
    version comparison via `major.minor.patch` components.
  - `ACCheckForUpdateView` (SwiftUI) + `ACCheckForUpdateViewFactory`
    (`@objc` bridge that hosts the SwiftUI view in an `NSWindowController`).
- **`CrossPromotion/`** — `ACCrossPromotionWindowController` for promoting the
  author's other apps.
- **`main.m`**, **`AppDelegate.h`**, **`VPNStatus.entitlements`** (location
  entitlement), **`Info.plist`** (`LSUIElement`, location usage strings),
  **`Base.lproj/*.xib`**, **`Assets.xcassets`** (menu bar icons:
  `VPNStatusItemOn/Off/Pause`).

### `VPNStatusTests/`

- `GitHubReleaseTests.swift` — exercises `GitHubRelease` ordering/equality,
  including prerelease/draft handling.
- `ACMenuReconcilerTests.m` — behavior tests for `ACMenuReconciler` (in-place
  menu updates: reuse/insert/remove/reorder, region isolation). Hosted on the
  `VPNStatus` app and run under the `VPNStatus` scheme (see "How to build and
  test").

### `VPNStatusUITests/`

`VPNStatusMenuUITests.swift` — XCUITest bundle that launches the **real**
`VPNStatus` menu-bar app and drives its live status-item menu end to end (status
item present, menu contents, connect/disconnect the real VPN, quit). See "UI
tests" and "Testing pitfalls" under "How to build and test" for the macOS
automation constraints and the `UITEST_AUTOMATION` activation hook it relies on.

## Key runtime conventions

### Notifications (the app's event bus)

State changes propagate via `NSNotificationCenter`. Know these four names:

| Notification | Posted by | Meaning |
|--------------|-----------|---------|
| `kSessionStateChangedNotification` | `ACNEService.refreshSession` | A VPN session's status changed → refresh UI. |
| `kACConfigurationDidChange` | `ACPreferences` (ignored SSIDs/VPNs setters) | Reload configurations and rebuild UI. |
| `kACMenuBarImageDidChange` | `ACPreferences.setMenuBarImageType:` | Re-render the status item icon. |
| `kACLocationManagerAuthorizationDidChange` | `ACLocationManager` | Location auth changed → refresh menu. |

All notifications are posted on the **main queue** so observers can update UI
directly.

### Threading

- `ACNEServicesManager.neServiceQueue` is a **serial dispatch queue** used for
  all `ne_session_*` callbacks. Session status callbacks fire there, then
  `dispatch_async` back to the main queue before touching model/UI state.
- UI and model mutation happen on the **main queue**. Follow this pattern for
  any new session work.

### Singletons

Nearly every service is a singleton accessed via a class method:
`ACNEServicesManager.sharedNEServicesManager`, `ACConnectionManager.sharedManager`,
`ACPreferences.sharedPreferences`, `ACLocationManager.sharedLocationManager`,
`UpdateManager.shared`. New shared services should follow the same pattern.

### Configuration filtering

`ACNEServicesManager.processConfigurations:` hides configurations that are:
- in the user's `IgnoredVPNs` list (default includes `"Little Snitch"`), or
- prefixed with `com.apple.preferences.` (internal macOS Sequoia entries).

### Objective-C ↔ Swift bridging

Swift code is exposed to Obj-C via the generated `VPNStatus-Swift.h` (imported
in `AppDelegate.m` and `ACPreferencesGeneralViewController.m`). Types meant to
cross the boundary are marked `@objc` (e.g. `UpdateManager`,
`ACCheckForUpdateViewFactory`). Obj-C headers exposed to Swift go through
`VPNStatus-Bridging-Header.h` (currently empty).

## Coding conventions to follow

- **The codebase is always clang-formatted.** Style is enforced by
  `.clang-format` (2-space indentation, no tabs; Attach braces — the opening
  brace stays on the same line, e.g. `if(x) {` and `void f() {`; no space before
  a control-keyword paren, e.g. `if(...)`; `NSString *foo` pointer alignment;
  method scope written `- (void)methodName`). Run `make format` before
  committing and `make format-check` to verify; do not hand-format against these
  rules. Note this means method declarations use `- (void)` (a space after the
  `-`/`+`), which clang-format enforces — the older mixed `-(void)` style is
  gone.
- Follow the remaining hand conventions clang-format does not cover:
  `in`-prefixed parameters (`inService`, `inValue`) and
  `NS_ASSUME_NONNULL_BEGIN/END` in headers.
- Prefer reusing the `Common/` core rather than duplicating VPN logic in a
  specific app target.
- Post the appropriate notification (above) when changing state that the UI
  should reflect, instead of poking UI directly across layers.
- Persist user-facing settings through `ACPreferences`, not raw
  `NSUserDefaults` calls scattered in the UI.
- When adding a private-API symbol, declare it in `ACDefines.h` alongside the
  existing ones and cite the source (as the existing comments do).
- **Logging uses `os_log` directly** (`os_log_fault`/`os_log_error`/`os_log`/
  `os_log_info`/`os_log_debug`), with Swift using `os.Logger`. No `NSLog`, no
  `debugPrint`, and no central logging wrapper — call the `os_log` API in place.
  Levels have fixed meanings: `fault` = severe unexpected errors, `error` =
  unexpected errors, `os_log` (notice) = expected errors, `info` = expected
  flow that is useful to log, `debug` = verbose/low-value tracing. Interpolated
  values use `%{public}@`. No `printf`/`fprintf` — there is no CLI in this repo
  any more.
- **Extra layers of indirection are always disfavored.** Do not add a wrapper,
  helper, factory, or abstraction "for no reason" — call the underlying API
  directly. Only introduce an indirection when it earns its keep with a concrete,
  present need.
- **Comments are disfavored except for genuinely non-obvious information.** Do
  not write file-header comments, block banners, or per-function description
  comments. Never write a comment that restates what the code already says — a
  redundant comment is always wrong because it must be kept in sync with the
  code it duplicates, so it should never have existed. Comment only the things
  the code cannot express: a surprising constraint, a hard-won macOS quirk, the
  reason behind a non-obvious choice.

## Gotchas / known rough edges

These are existing issues worth being aware of (part of "making this less
crappy"):

- **`ACNEService` never releases `_session` properly on the correct queue** and
  the class relies on private, undocumented `ne_session_*` APIs that can break
  across macOS releases.
- **Regex vs. exact match mismatch:** the Ignored SSIDs/VPNs UI
  (`ACPreferencesIgnoredViewController`) validates entries as **regular
  expressions**, but the actual filtering in `ACConnectionManager`
  (`shouldPreventAutoConnectOnCurrentSSID`) and `ACNEServicesManager`
  (`processConfigurations:`) uses **exact `containsObject:` string matching**.
  The README also describes SSIDs as exact, case-sensitive matches. The UI and
  behavior disagree.
- **Comma-delimited storage:** ignored SSIDs/VPNs are stored as a single
  comma-joined string, so values containing commas are not supported.
- **`menuBarImageForState:andType:` has no `return` in the outer `default:`**
  branch (potential undefined return).
- **`UpdateManager.checkForUpdate` completion is not always called** on some
  early-return paths (e.g. decode failure), which can leave the "up to date"
  alert flow inconsistent.
- **Version parsing** in `GitHubRelease` only understands numeric
  `major.minor.patch`; non-numeric tag components are dropped.

## Where to make common changes

- New VPN capability / status handling → `Common/ACNEService.*` and
  `Common/ACNEServicesManager.*`.
- Auto-connect behavior, timers, SSID rules → `Common/ACConnectionManager.*`.
- New persisted setting → `Common/ACPreferences.*` (add key + accessor + notify).
- Menu bar UI / menu items → `VPNStatus/AppDelegate.m`.
- Preferences window UI → `VPNStatus/PreferencesUI/*` + matching XIB in
  `VPNStatus/Base.lproj/`.
- Update checker → `VPNStatus/CheckForUpdate/*` (Swift).
