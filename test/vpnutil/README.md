# vpnutil — standalone NE VPN debugging CLI

A self-contained command-line tool for inspecting the NetworkExtension
(`NEConfiguration` / IKEv2) VPNs that macOS's stock tooling **cannot** see
(`scutil --nc`, `networksetup -listallnetworkservices` are blind to these).
It reaches into the private `NEConfigurationManager` / `ne_session_*` APIs —
the same code path the `VPNStatus` app uses — so it observes the real VPN state.

## Provenance

Built off the original `vpnutil` from
[https://github.com/Timac/VPNStatus](https://github.com/Timac/VPNStatus)
(Alexandre Colucci, blog.timac.org). Unlike the original (which linked the app's
`Common/` sources), this is a **single translation unit** with no dependency on
the app, so it builds with one `clang` command. It adds a `dump` command for
enhanced debugging.

## Build

```bash
clang -fobjc-arc -framework Foundation -framework SystemConfiguration \
      -framework NetworkExtension -o vpnutil vpnutil.m
```

No code signing required; it runs unsigned.

## Usage

```bash
./vpnutil list                 # JSON of {name, status} for every NE VPN
./vpnutil status <name>        # one line: "<name> <Status>"
./vpnutil dump <name>          # raw ne_session_get_info dictionaries for one VPN
./vpnutil dump                 # dump every VPN
./vpnutil watch <name>...      # dump the named VPNs once/second to stdout (Ctrl-C to stop)
```

`watch` re-queries status and re-dumps each named VPN every second — useful for
capturing state/field/cause transitions live (e.g. watching two VPNs while
disconnecting one). Two env vars tune how much each sample probes so a
multi-VPN sample fits in ~1s:

- `VPNUTIL_MAX_INFO` (default 12) — highest `infoType` selector to probe. Set to
  `2` to skip the always-timing-out selectors 3–12.
- `VPNUTIL_INFO_TIMEOUT` (default 2.0) — per-selector timeout in seconds. Set to
  e.g. `0.2` for a fast cadence.

```bash
VPNUTIL_MAX_INFO=2 VPNUTIL_INFO_TIMEOUT=0.2 ./vpnutil watch ares-staging test-vpn-<stamp>
```

## What `dump` shows

It probes `ne_session_get_info(session, infoType, ...)` for `infoType` 0–12
(configurable via `VPNUTIL_MAX_INFO`) and pretty-prints the raw XPC dictionary
for each. Empirically on macOS 15/26 only two selectors return data:

- **info type 1** — connection byte/packet statistics
  (`BytesIn/Out`, `PacketsIn/Out`, `ErrorsIn/Out`).
- **info type 2** — extended status. The useful fields:
  - `LastStatusChangeTime` — an `xpc_date`. **The reliable "connected since"
    timestamp.** It updates on every state transition (validated: it jumped to
    the disconnect moment when the VPN was turned off), and is present in both
    connected and disconnected states — so only interpret it as the *connect*
    time when the service state is actually Connected.
  - `IPv4` — tunnel interface name, addresses, router, routes (only while up).
  - `VPN.ConnectTime` — an `int64`. **Do NOT use as elapsed time.** Observed
    frozen/stale (e.g. 14356 for a ~7-minute-old session) and it disappears when
    disconnected. Not the current session's elapsed seconds.
  - `VPN.RemoteAddress` — server IP (only while connected).
  - `VPN.LastCause` — an `int64` disconnect cause; appears only when
    disconnected. See the open question below.
  - `ConnectionStatistics` — lifetime `ConnectCount` / `DisconnectedCount` /
    `MaxConnectTime` (longest-ever session, seconds).
  - `StartMessage` — PID/UID/GID of the process that started the session
    (while connected).

Other info types (0, 3–12) time out with no result.

`dump` also prints `[decoded]` lines for `LastStatusChangeTime` (as an NSDate)
and `VPN.LastCause` (mapped against the `NEVPNConnectionError` candidate names).

## Open question: what does `VPN.LastCause` actually map to?

The macOS SDK header
`NetworkExtension.framework/Headers/NEVPNConnection.h` defines the public
`NEVPNConnectionError` enum (domain `NEVPNConnectionErrorDomain`, macOS 13+)
with explicit integer values:

| Value | Constant | Value | Constant |
|------:|----------|------:|----------|
| 1 | Overslept | 11 | ClientCertificateExpired |
| 2 | NoNetworkAvailable | 12 | PluginFailed |
| 3 | UnrecoverableNetworkChange | 13 | ConfigurationNotFound |
| 4 | ConfigurationFailed | 14 | PluginDisabled |
| 5 | ServerAddressResolutionFailed | 15 | NegotiationFailed |
| 6 | ServerNotResponding | 16 | ServerDisconnected |
| 7 | ServerDead | 17 | ServerCertificateInvalid |
| 8 | AuthenticationFailed | 18 | ServerCertificateNotYetValid |
| 9 | ClientCertificateInvalid | 19 | ServerCertificateExpired |
| 10 | ClientCertificateNotYetValid | | |

**It is NOT yet confirmed that the private `VPN.LastCause` field uses this
enum.** A clean, user-initiated disconnect produces `LastCause == 1`, which the
enum labels "Overslept" — a poor fit for a manual stop. So either `LastCause` is
a *different* internal cause code (where `1` means a normal/user stop), or `1` is
a default/placeholder. To settle it, capture `LastCause` under known-cause
disconnects and build the mapping empirically, e.g.:

- Manual/user stop → observed `1`.
- Connect the throwaway `VPNStatus Test - Unreachable` config and let it fail
  (unreachable server) → read `LastCause`; a real failure code (e.g. server /
  resolution / negotiation) would confirm the field uses `NEVPNConnectionError`.
- Bad credentials → expect AuthenticationFailed if the enum applies.

## Caution

- These are **private, undocumented** APIs that can change across macOS
  releases. If a future macOS breaks them, the `ne_session_*` / `ne_session_get_info`
  declarations at the top of `vpnutil.m` are where it will surface.
- `list`/`status`/`dump` are read-only. This tool intentionally does **not**
  start/stop VPNs — use the app or the Homebrew `vpnutil` for that, and avoid
  disturbing a live connection while debugging.
