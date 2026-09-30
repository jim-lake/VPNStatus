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
| `VPNStatusTests` | Unit test bundle | XCTest target hosted on `VPNStatus`: `GitHubRelease` version parsing + `ACMenuReconciler` behavior + per-service row mapping + reconnect backoff + Min/Max Reconnect preferences. |
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
- **Deployment target:** macOS 15.0. **Swift version:** 5.0.
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
make test         # run the UI tests — THE PRIORITY (drives the real app)
make unit-test    # run the unit tests (secondary; validate before done)
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

**The UI tests are the priority.** They drive the REAL menu-bar app end to end
and are the only tests that exercise the ACTUAL app the user runs — so `make
test` is wired to them. The unit tests (`make unit-test`) cover isolated logic
(version parsing, the menu reconciler, row mapping, backoff/preferences,
auto-connect policy) and are mostly a sanity check on that logic, not the
running app. Validate the unit tests before you're done, but treat the UI tests
as the real signal: if you change app behavior, the UI tests are what proves it
still works.

The `VPNStatusTests` unit bundle covers `GitHubRelease` version comparison
(Swift), the menu reconciler (`ACMenuReconcilerTests.m`, Obj-C), the per-service
row title/action mapping (`AppDelegateServiceRowTests.m`), the reconnect
backoff (`ACConnectionManagerBackoffTests.m`), the Min/Max Reconnect
preferences (`ACPreferencesReconnectTests.m`), and the arm-on-connect
auto-connect policy (`ACAutoConnectPolicyTests.m`). The reconciler's `.m` is
compiled into both the `VPNStatus` app target and the test target so the tests
link its symbols directly; the backoff/preferences/auto-connect tests instead
resolve their symbols against the host app (`BUNDLE_LOADER`). `ACConnectionManager`
and `ACAutoConnectPolicy` each expose their full surface (including the pieces
tests seed/inspect) from their single public header — there is no separate
`_Internal.h` header. The test target's `HEADER_SEARCH_PATHS` includes
`$(SRCROOT)/Common`.

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
# UI tests — same unsigned flags as everything else.
xcodebuild -project VPN.xcodeproj -scheme VPNStatusUITests -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test
```

> **Signing:** the UI tests build and pass with `CODE_SIGNING_ALLOWED=NO`, the
> same flags as the app and unit builds (verified end to end on this project —
> `make test` runs green). There is no need to allow signing for the UI scheme.
> Wrap UI-test runs in a `timeout` (the `Makefile` does) so a wedged automation
> run can't block indefinitely.

> **Rule for this repo's docs:** never add a line to any Markdown file (this file,
> `AUTO_CONNECT.md`, or any other) claiming that tests cannot be run — for any
> reason (SSH, "no GUI/Aqua session", session type, etc.). Tests can always be
> run here. Do not reintroduce such claims.

The toggle test (`testClickingServiceTogglesConnection`) verifies the real VPN
state by shelling out to `vpnutil`. `vpnutil` is **not** built from this repo any
more — install it from Homebrew (`brew install timac/vpnstatus/vpnutil`). The
test looks for it at `/opt/homebrew/bin/vpnutil` or `/usr/local/bin/vpnutil`; if
it is absent the toggle test is skipped (the others still run).

The tests:

- `testStatusItemAppears` — the `NSStatusItem` shows in the menu bar. It carries
  `accessibilityIdentifier = "VPNStatusItem"` (set on `statusItem.button` in
  `AppDelegate`).
- `testMenuShowsStaticItems` — opening the menu shows `Settings…`
  (`static.settings`) and `Quit VPNStatus` (`static.quit`).
- `testMenuShowsAServiceActionRow` — the real VPN renders a
  `Connect/Disconnect <name>` row.
- `testClickingServiceTogglesConnection` — activates the service row and confirms
  via `vpnutil` that the real VPN flips state, then flips back
  (Connected → Disconnected → Connected).
- `testCleanCLIDisconnectDisablesAutoConnect` — the end-to-end proof of the
  clean-disconnect policy. Connects the local `test-vpn-*` target **through the
  app** (which arms and, on reaching Connected, commits always-auto-connect),
  then disconnects it **out of band via `vpnutil stop`** — a clean, user-initiated
  stop. Asserts the VPN then **stays Disconnected for 30s (no auto-reconnect)**
  and that the menu row's title tracks the whole sequence
  (`Connect <name>` → `Disconnect <name>` → back to `Connect <name>`). It
  establishes a relaunch-safe clean baseline first (terminate app, `vpnutil stop`,
  clear the service's persisted `AlwaysConnected` flag via PlistBuddy +
  `killall cfprefsd`, relaunch) because a prior run commits the flag and the app
  would otherwise auto-reconnect on launch. Skips if `vpnutil` or the
  `test-vpn-*` target is absent / unreachable. Note it verifies state via the
  **row title**, not the checkmark: XCUITest does **not** expose the
  `NSMenuItem` checkmark for popped-up status-menu rows (`isSelected`/`value` are
  always empty), so the title is the observable indicator — and it fully encodes
  the checkmark (`Disconnect <name>` == checked, `Connect <name>` == unchecked).
- `testConnectingRowShowsConnectingTitle` — when a service is Connecting, the
  row is a plain `NSMenuItem` titled `Disconnect <name> - Connecting...` (with a
  checkmark). Reads the row's title **through XCUITest accessibility** and
  asserts it starts with `Disconnect ` and ends with the literal ` - Connecting...`
  (three periods, not a `…` ellipsis). Skipped (not failed) when nothing is
  currently Connecting; start a slow/unreachable VPN to exercise it (the dev
  machine has a `VPNStatus Test - Unreachable` config that lingers in
  Connecting).
- `testDumpOpenMenuMetrics` — diagnostic (not an assertion): opens the menu and
  prints every row's frame plus every static-text label's identifier/value/frame,
  and attaches a screenshot of the open menu. Use it when inspecting menu row
  layout. Reads only external accessibility (frames + label values), never
  in-process/introspected state.
- `testQuitTerminatesApp` — activates Quit and confirms the app terminates.

**HARD GATE: the menu must actually open before any test measures anything.**
`openStatusMenu()` is a `throws` precondition every menu test calls as its first
line (`try openStatusMenu()`). It is a **hard stop**: if the menu does not open,
the test fails and aborts *there*, before any reads or assertions.
- "Open" is defined as the `static.quit` row having a **real, non-zero on-screen
  frame** — NOT mere existence in the AX tree. A *closed* status menu still
  exposes its rows in the accessibility tree with zero-size frames
  (`{0,1080,0,0}`), so an existence check passes while the menu is actually shut.
  Always gate on a non-zero frame.
- It retries `app.activate()` + `statusItem().click()` up to 8×, waiting for the
  real frame to appear each time, then `XCTFail(...) + throw` if still closed.
  With `continueAfterFailure = false` this aborts immediately.
- Never move past a failed open. Nothing downstream is meaningful if the menu
  isn't really on screen.

**Verify what the menu actually shows via accessibility, not introspection.** To
check a row's rendered text, read the `NSMenuItem`'s `title` through XCUITest and
assert on it, not the app's own state. Every per-service row is a plain
`NSMenuItem`.

How the automation works:

1. **Reading a status-item menu works.** After `statusItem().click()` opens the
   menu, XCUITest can read the rows' stable identifiers/titles. When the menu is
   genuinely open the rows have real, non-zero on-screen frames and are hittable
   (verified: a row's `.click()` returns in ~1.3s and dispatches its real
   action). The catch is a *closed* status menu still lists its rows in the AX
   tree but with **zero-size frames** (`{0,1080,0,0}`), so you must gate on a
   real frame — see the HARD GATE above — not mere existence.
2. **The tests activate rows through a UI-test hook** (not because clicking is
   impossible — it works — but because the hook is deterministic and needs no
   on-screen hit-testing). When launched with `UITEST_AUTOMATION=1` (set via
   `launchEnvironment`), `AppDelegate` observes an `NSDistributedNotification`
   (`org.timac.VPNStatus.uitest.activate`, object = row identifier) and calls
   `-[NSMenu performActionForItemAtIndex:]`, which dispatches the row's real
   target/action exactly as a click would
   (`connectService:`/`disconnectService:`/`doQuit:`). The hook is inert unless
   the env var is set. The menu *contents* the tests assert on are read from the
   live menu by XCUITest; only the *activation* goes through the hook.
3. **Queries scope to the status item's own menu** (`statusItem().menuItems`),
   not the global `app.menuItems`, so a synthesized app menu bar can't introduce
   an ambiguous second `Settings…`/`Quit VPNStatus` match.
4. **Opening the menu is retried** (`app.activate()` + click) because a status
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

### Testing notes

- **Observe the app through XCUITest, not the app's own state.** To check a
  row's rendered text, read the `NSMenuItem`'s `title` through XCUITest and
  assert on it. XCUITest can read a row's title but **not** its checkmark
  (`isSelected`/`value` are always empty for popped-up status-menu rows), so
  assert on the title — it encodes the same state (`Disconnect <name>` is
  checked, `Connect <name>` is unchecked).
- **Don't run `xcodebuild` as root or under `sudo`** (or with a `sudo`-owned
  `-derivedDataPath`): it leaves root-owned build artifacts you then can't clean
  up without `sudo`. Run as the normal user.

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
    `connect`, `disconnect`, `cancel`.
  - **`connect`/`disconnect`/`cancel` and the `ne_session_*` truth.**
    `connect` → `ne_session_start`, `disconnect` → `ne_session_stop`. `cancel`
    (used to abort an in-progress `Connecting` attempt) ALSO uses
    `ne_session_stop` — **not** `ne_session_cancel`. `ne_session_cancel` tears
    down the client-side session object (it is what `-dealloc` uses before
    `ne_session_release`); it does NOT stop the daemon's negotiation, so calling
    it on a `Connecting` session leaves it stuck at `Connecting` forever. Only
    `ne_session_stop` actually drives `Connecting → Disconnecting → Disconnected`
    and fires the event handler that refreshes the UI. Do not "fix" `cancel` back
    to `ne_session_cancel`.

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
  - Exposes its full surface (backoff bookkeeping included) from the single
    `ACConnectionManager.h`; there is no `_Internal.h`.

- **`ACAutoConnectPolicy.{h,m}`** — Singleton owning the **arm-on-connect
  intent state machine** that decides *when* a service becomes
  always-auto-connect (as opposed to `ACConnectionManager`, which owns the
  *mechanism*: the persisted flag + reconnect/backoff). A user Connect request
  (`requestConnectService:`) **arms** the service in an in-memory set
  (`armedServiceIdentifiers`, never persisted) and starts the connection.
  Observing `kSessionStateChangedNotification`, an armed service that reaches
  **Connected** commits always-auto-connect (via
  `ACConnectionManager.setAlwaysAutoConnect:`) and disarms; one that reaches
  **Disconnected** (a failed attempt) disarms without committing.
  `requestDisconnectService:` / `requestCancelService:` /
  `requestDisconnectServices:` disarm and disable always-auto-connect
  immediately. Because the armed set lives only in memory, quitting the app
  clears it — auto-connect is enabled only by a successful Connect within the
  same process run. It also **disables auto-connect on any clean disconnect**,
  not just app-initiated ones: observing `kSessionStateChangedNotification`, an
  always-auto-connect service that reaches **Disconnected** *cleanly*
  (`handleAlwaysConnectState:wasClean:forService:` with `wasClean == YES`) has
  its always-auto-connect flag cleared via
  `ACConnectionManager.setAlwaysAutoConnect:NO`, which also cancels the reconnect
  backoff loop. "Clean" means a user-initiated stop — detected in `ACNEService`
  by reading `ne_session_get_info` type 2 on the disconnect event and checking
  `VPN.LastCause == 1` with no `LastDisconnectError` (see `NE_PRIVATE_VPN.md`),
  surfaced as `ACNEService.lastDisconnectWasClean`. So disconnecting the VPN from
  System Settings (or `vpnutil`), or mid-reconnect-loop, turns auto-connect off
  for that VPN. **Involuntary** drops (server death/abort, network change,
  collateral kill — any non-1 cause with a `LastDisconnectError`) leave the flag
  on so `ACConnectionManager` reconnects. Exercised by `ACAutoConnectPolicyTests`.

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
  code is the code that runs. Every row it produces is a plain `NSMenuItem`
  (title/action/state/enabled/representedObject); there is no custom
  `NSMenuItem.view` any more.

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
    connect/disconnect rows, and a static Settings/Quit block built once. Every
    per-service row is a plain `NSMenuItem`. A **connected** row is titled
    `Disconnect <name>` with a checkmark; a **disconnected** row is titled
    `Connect <name>` with no checkmark. A service that is **Connecting** is a row
    titled `Disconnect <name> - Connecting...` with a checkmark; its action is
    `cancelService:`, which aborts the attempt via `ACNEService.cancel`
    (`ne_session_stop`). A `Disconnecting` service is a plain, non-actionable
    `Disconnecting <name>...` row. There is no pause section, no per-service info
    block, and no Location Services prompt in the menu.
  - The per-service row title/action for each state lives in
    `titleForServiceActionState:name:` / `actionForServiceActionState:` and is
    unit-tested (`AppDelegateServiceRowTests`). Note both the `Connecting` and
    `Disconnecting` titles end in three literal periods `...`, not the `…`
    ellipsis character.
  - **Auto-connect uses an arm-on-connect state machine.** The menu actions
    express *intent* and delegate to `ACAutoConnectPolicy` (`Common/`):
    - `connectService:` calls `-requestConnectService:`, which **arms** the
      service (records an in-memory intent) and starts the connection. It does
      **not** enable always-auto-connect yet. Only when the armed service
      actually transitions to **Connected** (observed via
      `kSessionStateChangedNotification`) does the policy commit
      always-auto-connect. If the attempt fails instead (Connecting →
      Disconnected), the service is disarmed and the flag is never set.
    - `disconnectService:` → `-requestDisconnectService:` disables
      always-auto-connect **immediately** (disarm + clear the persisted flag)
      and stops the VPN, so the reconnect timer won't bring it back.
    - `cancelService:` → `-requestCancelService:` disarms, disables
      always-auto-connect, and aborts the attempt.
    - `disconnectAll:` → `-requestDisconnectServices:` disarms + disables +
      stops every connected service.
    The **armed set is in-memory only** (`armedServiceIdentifiers`), never
    persisted: quitting the app clears it, so an interrupted connect can never
    arm across process runs. Only a successful connect within the *same* run
    enables auto-connect. `ACAutoConnectPolicy` owns *when* a service becomes
    always-auto-connect; `ACConnectionManager` still owns the *mechanism* (the
    persisted flag write via `setAlwaysAutoConnect:` plus reconnect/backoff).
    There is no "Always auto connect" toggle row and no pause controls.
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
- **Comments are disfavored and are the exception, not the rule.** The default
  is **no comment**. Every comment is a liability: it must be re-verified and
  churned on *every* nearby code change, on top of the actual code edit, and a
  stale comment is worse than none. A comment only earns its place if it
  documents something the code genuinely *cannot* express. The **only**
  acceptable reasons to write a comment are:
  1. **Undocumented / private Apple API behavior** — e.g. the `ne_session_*`
     calls in `ACDefines.h`/`ACNEService.m`, why `cancel` uses `ne_session_stop`
     rather than `ne_session_cancel`, or citing the `configd` source a private
     symbol came from.
  2. **A hard-won OS quirk or non-obvious constraint** — e.g. the macOS
     status-menu automation constraints in the UI tests, or why clicking a
     popped-up status-menu row hangs XCUITest (so activation goes through the
     distributed-notification hook instead).
  3. **A genuinely surprising, non-obvious *why*** behind a choice that the code
     itself cannot convey and that the next reader would otherwise get wrong.

  Everything else is **banned**, with no exceptions:
  - **No file-header comments** (the `// Foo.m / Created by … / Copyright …`
    banners). Do not add them to new files and remove them when editing.
  - **No per-function / per-method description comments.** A method's name and
    signature are the documentation. Do not narrate what a function does above
    it.
  - **No block-banner / section-divider comments**, and no comments that restate
    the code on the next line (`// increment i`, `// the trailing separator`,
    `// Connect`, `// Save the preferences`, etc.). If the comment could be
    deleted without losing information a competent reader doesn't already have
    from the code, it must be deleted.

  These big descriptive comments are exactly the ones that rot: they force a
  churn on every change and drift out of sync. When in doubt, delete the comment
  and let the code speak. Prefer clearer names and smaller functions over
  explanatory prose.

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
- Auto-connect *mechanism* (reconnect timers, backoff, SSID rules) →
  `Common/ACConnectionManager.*`.
- Auto-connect *policy* (when a Connect commits to always-auto-connect; the
  arm-on-connect state machine) → `Common/ACAutoConnectPolicy.*`.
- New persisted setting → `Common/ACPreferences.*` (add key + accessor + notify).
- Menu bar UI / menu items → `VPNStatus/AppDelegate.m`.
- Preferences window UI → `VPNStatus/PreferencesUI/*` + matching XIB in
  `VPNStatus/Base.lproj/`.
- Update checker → `VPNStatus/CheckForUpdate/*` (Swift).
