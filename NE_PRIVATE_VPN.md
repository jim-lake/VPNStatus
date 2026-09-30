# NetworkExtension private VPN status — empirical field reference

Documents the raw data returned by the private `ne_session_get_info()` API for
NetworkExtension (`NEConfiguration` / IKEv2) VPNs, and — the main goal — what the
undocumented **disconnect cause** fields actually mean, established empirically
against a real IKEv2 server rather than guessed from the public SDK enum.

- **Platform:** macOS 26 (validated on this dev machine), Apple silicon.
- **Tooling:** `test/vpnutil/vpnutil dump <name>` (raw `ne_session_get_info`
  dictionaries) plus a small decoder for the serialized `LastDisconnectError`
  NSError, cross-checked against `log show` (`nesessionmanager` /
  `com.apple.networkextension`) and the server-side strongSwan `journalctl`.
- **Test target:** the local strongSwan IKEv2 VPN in `test/target_vpn/`
  (split tunnel, server `192.168.1.222`, DPD delay 30s).

> **These are private, undocumented APIs.** Field names, numeric codes, and even
> which selectors return data can change between macOS releases. Everything below
> is observed behavior on the platform above, not a contract.

## `ne_session_get_info(session, infoType, …)` selectors

Probed `infoType` 0–12. Only **1** and **2** ever return a dictionary; all
others time out with no result (matches the prior `test/vpnutil` notes).

### info type 1 — byte/packet counters

```
VPN => {
  PacketsIn, BytesIn, ErrorsIn,
  PacketsOut, BytesOut, ErrorsOut
}
```

Live and monotonic for the **current** session. Verified: idle right after
connect they read 0/0; after pushing 5 pings through the tunnel gateway they
rose to `PacketsIn=12 BytesIn=1008 / PacketsOut=8 BytesOut=896`. Reset to 0 on a
new session.

### info type 2 — extended status

Full example while **Connected**:

```
LastStatusChangeTime = <date>              # updates on EVERY state transition
IsPrimaryInterface   = 0                    # 1 only for a full-tunnel/default route VPN
SessionState         = 4                    # see state-code table below
NEStatus             = 3
Status               = 2
ConnectionStatistics = {
  ConnectCount, ConnectedCount,             # lifetime counters (persist across sessions)
  DisconnectedCount,
  MaxConnectTime                            # longest-ever session length, seconds
}
IPv4 = {                                    # present ONLY while Connected
  InterfaceName  = "ipsec0"
  Addresses      = [ "10.199.10.1" ]
  Router         = "10.199.10.1"
  AdditionalRoutes = [ { DestinationAddress, SubnetMask, GatewayAddress } ]
  ServerAddress  = "192.168.1.222"
}
VPN = {                                     # shape depends on state (see below)
  ConnectTime   = 22083                     # int64, present only while Connected — see caveat
  RemoteAddress = "192.168.1.222"           # present only while Connected
}
StartMessage = {                            # the process that started the session
  SessionPID, SessionUserID, SessionGroupID, SessionCommandType
}
LastDisconnectError = <data: bplist>        # present only after an ERROR disconnect (see below)
```

Notes / caveats confirmed here:

- **`LastStatusChangeTime`** (`xpc_date`) is the reliable "since" timestamp — it
  jumps to the moment of the latest transition (connect *or* disconnect). Only
  read it as "connected since" when the state is actually Connected.
- **`VPN.ConnectTime`** (int64) is **not** elapsed seconds. Observed values like
  `21867` / `22083` for sessions only seconds old, drifting between connects. Do
  not use it as a duration; it disappears when disconnected. Use
  `LastStatusChangeTime` for timing.
- **`ConnectionStatistics`** are lifetime totals held by the daemon and persist
  across sessions (e.g. `DisconnectedCount` climbed to 63 after repeated
  unreachable-server retries). `MaxConnectTime` is the longest single session
  ever, in seconds.
- **`IPv4`**, **`VPN.RemoteAddress`**, **`VPN.ConnectTime`** appear only while
  Connected; the `VPN` sub-dictionary is **empty** while Connecting and carries
  only `LastCause` once disconnected.

## The event handler (`ne_session_set_event_handler`) — push path

`ne_session_set_event_handler(session, queue, ^(ne_session_event_t event, void
*event_data){…})` is the *push* notification the app relies on to know when to
refresh. We instrumented it directly (register the handler, log the raw `event`
int and inspect `event_data`) across many transitions — clean connect, connect
retries, clean disconnect, **and** an error disconnect (server killed):

| Transition observed | `event` | `event_data` |
|---------------------|:-------:|:------------:|
| → Connected | 1 | NULL |
| → Connecting (incl. retries) | 1 | NULL |
| → Disconnecting | 1 | NULL |
| → Disconnected (clean) | 1 | NULL |
| → Disconnected (error / server death) | 1 | NULL |

**The event carries no payload.** `event` was **always `1`** and `event_data`
was **always `NULL`**, including on error disconnects. It is a bare "state
changed, come re-query" poke — it does **not** deliver the status, and it does
**not** deliver the cause. So:

- To get the new **status** you must call `ne_session_get_status` (what the app
  already does in `refreshSession`).
- To get the **cause** (`LastCause` / `LastDisconnectError`) you must call
  `ne_session_get_info` type 2 — the event never contains it.

This validates `ACNEService`'s current design (event → `refreshSession` →
`ne_session_get_status`): nothing useful is being thrown away by ignoring
`event`/`event_data`. If the app ever wants to surface disconnect *reasons*, the
event is the right trigger, but it must then additionally read
`ne_session_get_info` type 2 on that poke — the reason will not arrive in the
callback itself.

## State code triples (`SessionState` / `NEStatus` / `Status`)

The three integer state fields in info type 2 move together. Observed:

| User-visible state | `SessionState` | `NEStatus` | `Status` |
|--------------------|:--------------:|:----------:|:--------:|
| Disconnected       | 1              | 1          | 0        |
| Connecting         | 3              | 2          | 1        |
| Connected          | 4              | 3          | 2        |
| Disconnecting      | 5              | 5          | 3        |

`Status` matches the `SCNetworkConnectionStatus` values the app already uses
(`Disconnected=0, Connecting=1, Connected=2, Disconnecting=3, Invalid=4`
per `SCNetworkConnectionGetStatusFromNEStatus`). `NEStatus` and `SessionState`
are separate private enumerations that track alongside it. (Disconnecting is a
brief transient; the values above are the ones captured at rest.)

## The headline: `VPN.LastCause` and `LastDisconnectError`

`VPN.LastCause` (int64) appears **only after a disconnect** (absent while
Connected or Connecting). When the disconnect was an **error**, a companion
`LastDisconnectError` field is also present — a serialized (`NSKeyedArchiver`)
`NSError` that carries the **authoritative domain + code + message**. A clean
user stop has a `LastCause` but **no** `LastDisconnectError`.

**`VPN.LastCause` is NOT the public `NEVPNConnectionError` enum.** That was the
open question in the old `test/vpnutil` notes, and it is now settled: the codes
do not line up (a clean user stop yields `1`, and different failures pull codes
from *different* internal error domains — see below). The public
`NEVPNConnectionError` "candidate" labels the dump prints are therefore
misleading and should be ignored.

### Empirically measured causes

Each row below was produced under a **known** disconnect condition and captured
from the live session:

| Disconnect condition | `LastCause` | `LastDisconnectError` domain | code | Localized message | `nesessionmanager` stop reason |
|----------------------|:-----------:|------------------------------|:----:|-------------------|--------------------------------|
| Clean user stop (`ne_session_stop`) | **1** | *(none — no error field)* | — | — | `Stop command received` / `Plugin initiated` |
| Server unreachable / never answers (connect to dead endpoint, then aborted) | **20** | `NEVPNConnectionErrorDomainPlugin` | 20 | "The VPN server is not responding." | — |
| Server dies mid-session (hard VM kill; detected via DPD ~30s once traffic flows) | **20** | `NEVPNConnectionErrorDomainPlugin` | 20 | "The VPN server is not responding." | `Server is not responding` |
| Server gracefully terminates the tunnel (`systemctl stop strongswan` → IKE DELETE) | **21** | `NEVPNConnectionErrorDomainPlugin` | 21 | "The VPN session was aborted by the VPN server." | `Tunnel was terminated by the server` |
| Authentication failure (server rejects client identity → IKE `N(AUTH_FAILED)`) | **3** | `IKEv2ProviderDisconnectionErrorDomain` | 3 | *(no localized string; "…error 3.")* | `Plugin initiated` |
| **Collateral kill** — a *different* IKEv2 VPN was disconnected and took this one down with it (shared extension process; see below) | **7** | `NEVPNConnectionErrorDomainPlugin` | 7 | "The VPN session failed because an internal error occurred." | `Plugin failed` |

### What this tells us about the encoding

- **`LastCause` mirrors the underlying error's `code`, across *different*
  domains.** For the plugin-level failures the number equals the
  `NEVPNConnectionErrorDomainPlugin` code (20, 21). For the auth failure it
  equals the `IKEv2ProviderDisconnectionErrorDomain` code (3). So `LastCause` is
  **not** a single flat enum — it is "the code of whatever `NSError` most
  recently ended the session," and you must look at `LastDisconnectError.domain`
  to interpret it. Two different domains can (and here do — value 3 vs the
  plugin domain's low codes) collide numerically.
- **`LastCause == 1` is the sentinel for a normal, user-initiated stop** (no
  error object attached). Do not map it to the public enum's `1` ("Overslept").
- **Value 20 = "server not responding"** covers both *never reachable* and
  *died mid-session* — they are indistinguishable by cause code (both DPD /
  no-response). Distinguish them by whether the session ever reached Connected
  (`ConnectionStatistics.ConnectedCount`, `MaxConnectTime`) if you need to.
- **Value 21 = "aborted by the server"** is a *graceful* server teardown (the
  peer sent an IKE DELETE), distinct from 20's silence.

### Two error domains seen

| Domain | Meaning | Codes observed |
|--------|---------|----------------|
| `NEVPNConnectionErrorDomainPlugin` | High-level NE plugin disconnect reasons | 7 (internal error / "Plugin failed"), 20 (server not responding), 21 (aborted by server) |
| `IKEv2ProviderDisconnectionErrorDomain` | IKEv2 provider-specific negotiation failures | 3 (auth failed, from server `N(AUTH_FAILED)`) |

## Corroboration from Apple's own binaries (authoritative, not inferred)

The empirical findings above were cross-checked against Apple's shipping
binaries and resources on the same OS. All read-only inspection
(`strings`/`plutil`/SDK headers). This confirms the field/enum **names** and,
critically, **why there are multiple code spaces**.

### The two-domain rule is documented by Apple

`NEVPNConnection.h` (SDK) on `-[NEVPNConnection lastDisconnectError]` states, in
substance: if the VPN system (including the IPsec client) generated the error it
is in `NEVPNConnectionErrorDomain`; **if a *tunnel provider app extension*
generated it, the error is the NSError the provider passed at disconnect.**
(Content rephrased from the header for licensing compliance.) That is exactly
what we observed: IKEv2 auth failure surfaced `IKEv2ProviderDisconnectionErrorDomain`
(the IKEv2 *provider* extension's own NSError), while system-side teardowns
surfaced the private `NEVPNConnectionErrorDomainPlugin`.

### `NEVPNConnectionErrorDomainPlugin` codes are NOT the public enum

The public `NEVPNConnectionError` enum (from `NEVPNConnection.h`, macOS 13+) is:

| # | Public constant | # | Public constant |
|--:|-----------------|--:|-----------------|
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

Our measured `NEVPNConnectionErrorDomainPlugin` values do **not** line up with
this: we saw server-not-responding = **20** (public "ServerNotResponding" is 6),
server-aborted = **21** (public "ServerDisconnected" is 16), internal-error = **7**.
So the private `…Plugin` domain has its **own** numbering, offset from and
independent of the public enum. Match by the **message string**, never by
assuming the public enum's number.

### Apple's authoritative disconnect-reason key set

`NetworkExtension.framework/…/Resources/Localizable.loctable` contains a
complete `VPN_DISCONNECT_ERROR_*` key→message table (extract with
`plutil -extract en xml1`). These are Apple's own constant names and the exact
strings that appear in `LastDisconnectError.userInfo[NSLocalizedDescription]`.
The full set (macOS 26):

| Key | Message |
|-----|---------|
| `…_AUTHENTICATION_FAILED` | The VPN credentials are invalid. |
| `…_CLIENT_CERTIFICATE_EXPIRED` | The VPN client certificate has expired. |
| `…_CLIENT_CERTIFICATE_INVALID` | The VPN client certificate is invalid. |
| `…_CLIENT_CERTIFICATE_MISSING` | The VPN client certificate is missing from the configuration. |
| `…_CLIENT_CERTIFICATE_NOT_YET_VALID` | The VPN client certificate is not yet valid. |
| `…_CONFIGURATION_APP_REQUIRED` | The VPN cannot be started on demand. |
| `…_CONFIGURATION_FAILED` | The VPN session disconnected because the configuration is invalid. |
| `…_CONFIGURATION_NOT_FOUND` | The VPN configuration could not be found. |
| `…_CONNECTION_ERROR` | The VPN connection could not be established. |
| `…_CONNECT_TIMEOUT` | The VPN session failed to connect in a timely manner. |
| `…_INTERNAL_ERROR` | The VPN session failed because an internal error occurred. |
| `…_NETWORK_CHANGE` | The VPN session disconnected because the device connected to a different network. |
| `…_NO_NETWORK_AVAILABLE` | The VPN session disconnected because the device was not connected to a network. |
| `…_OVERSLEPT` | The VPN session timed out while the device was asleep. |
| `…_PLUGIN_NOT_AVAILABLE` | The VPN app used by the VPN configuration is not installed. |
| `…_SERVER_ADDRESS_INVALID` | The VPN server address in the configuration is invalid. |
| `…_SERVER_ADDRESS_MISSING` | The VPN server address is missing from the configuration. |
| `…_SERVER_ADDRESS_RESOLUTION_FAILED` | The VPN server hostname could not be resolved to an IP address. |
| `…_SERVER_CERTIFICATE_EXPIRED` | The VPN server certificate has expired. |
| `…_SERVER_CERTIFICATE_INVALID` | The VPN server certificate is invalid. |
| `…_SERVER_CERTIFICATE_NOT_YET_VALID` | The VPN server certificate is not yet valid. |
| `…_SERVER_DEAD` | The VPN server stopped responding. |
| `…_SERVER_DISCONNECTED` | The VPN session was aborted by the VPN server. |
| `…_SERVER_NEGOTIATION_FAILED` | The VPN protocol negotiation with the VPN server failed. |
| `…_SERVER_NOT_RESPONDING` | The VPN server is not responding. |
| `…_SHARED_SECRET_MISSING` | The VPN shared secret is missing from the configuration. |

(All keys prefixed `VPN_DISCONNECT_ERROR_`.) Our measured causes map by message:
`SERVER_NOT_RESPONDING` = code **20**, `SERVER_DISCONNECTED` = code **21**,
`INTERNAL_ERROR` = code **7**. Note `SERVER_DEAD` ("stopped responding") is a
*distinct* key from `SERVER_NOT_RESPONDING` — we have not yet observed its
private-domain code.

### `nesessionmanager` symbol names (confirming our dump field/enum names)

`strings /usr/libexec/nesessionmanager` confirms — verbatim — every extended-status
field name we reverse-engineered (`LastStatusChangeTime`, `LastCause`,
`LastDisconnectError`, `ConnectionStatistics`, `ConnectCount`, `ConnectedCount`,
`DisconnectedCount`, `MaxConnectTime`, `IsPrimaryInterface`, `SessionState`,
`NEStatus`, `StartMessage`, `SessionCommandType`), plus `SessionInfoType` and the
`copyExtendedStatus` / `notifyChangedExtendedStatus` / `handleGetInfoMessage:withType:`
methods (so info type 2 is Apple's "extended status").

It also exposes the internal session **state machine** names (richer than the 4
user-visible states):

```
NESMVPNSessionStateIdle, IdleIPC, Starting, Authenticating, PreparingNetwork,
Running, Reasserting, Updating, Stopping, Disposing
```

These are the `nesessionmanager` state names printed in the logs (`Entering state
NESMVPNSessionStateStarting`, etc.); the numeric `SessionState`/`NEStatus`
fields in the dump are a *separate, smaller* status enumeration (the 1/3/4/5
values in the state-code table above), not a 1:1 index into this list.

### Complete private code→key tables (decoded from the framework binary)

The numeric-code → `VPN_DISCONNECT_ERROR_*` key resolver is
`+[NEVPNConnection createDisconnectErrorWithDomain:code:]` in the
`NetworkExtension` framework. That binary now ships **only inside the dyld shared
cache**, so it was extracted with `ipsw dyld extract` and the two `switch`
jump-tables were disassembled/decoded (`ipsw macho disass` + parsing the
`__cfstring` targets). The method builds the localized NSError by switching on
`code` **per domain**, and there are **two** private system domains with
**independent numbering** (plus the provider domain from tunnel extensions):

**`NEVPNConnectionErrorDomainPlugin`** (modern NE path — IKEv2 etc.; this is what
our `LastCause` / `LastDisconnectError` used):

| code | key (`VPN_DISCONNECT_ERROR_` +) | measured? |
|-----:|--------------------------------|-----------|
| 2  | OVERSLEPT | |
| 4  | NO_NETWORK_AVAILABLE | |
| 5  | NETWORK_CHANGE | |
| 6  | PLUGIN_NOT_AVAILABLE | |
| 7  | INTERNAL_ERROR | ✅ collateral kill |
| 10 | CONFIGURATION_FAILED | |
| 12 | CONNECT_TIMEOUT | |
| 14 | CONFIGURATION_APP_REQUIRED | |
| 15 | SERVER_ADDRESS_MISSING | |
| 16 | SERVER_ADDRESS_INVALID | |
| 17 | SERVER_ADDRESS_RESOLUTION_FAILED | |
| 18 | SERVER_NEGOTIATION_FAILED | |
| 20 | SERVER_NOT_RESPONDING | ✅ hard kill / unreachable |
| 21 | SERVER_DISCONNECTED | ✅ graceful server stop |
| 22 | SERVER_DEAD | |
| 23 | AUTHENTICATION_FAILED | |
| 24 | CLIENT_CERTIFICATE_MISSING | |
| 25 | CLIENT_CERTIFICATE_INVALID | |
| 26 | CLIENT_CERTIFICATE_NOT_YET_VALID | |
| 27 | CLIENT_CERTIFICATE_EXPIRED | |
| 28 | SERVER_CERTIFICATE_INVALID | |
| 29 | SERVER_CERTIFICATE_NOT_YET_VALID | |
| 30 | SERVER_CERTIFICATE_EXPIRED | |
| 38 | CONFIGURATION_NOT_FOUND | |

(Codes 1, 3, 8, 9, 11, 13, 19, 31–37 have no dedicated key and fall to the
default. **Code 1 is the clean-user-stop sentinel** — no error object is built,
which is why a normal stop shows `LastCause == 1` and no `LastDisconnectError`.)

**`NEVPNConnectionErrorDomainIPSec`** (legacy IPSec/racoon client — *different*
numbering; note e.g. INTERNAL_ERROR is 8 here but 7 in the Plugin domain):

| code | key (`VPN_DISCONNECT_ERROR_` +) | | code | key |
|-----:|----|-|-----:|-----|
| 2 | SERVER_ADDRESS_MISSING | | 14 | AUTHENTICATION_FAILED |
| 3 | SHARED_SECRET_MISSING | | 15 | NETWORK_CHANGE |
| 4 | CLIENT_CERTIFICATE_MISSING | | 16 | SERVER_DISCONNECTED |
| 5 | SERVER_ADDRESS_RESOLUTION_FAILED | | 17 | SERVER_DEAD |
| 6 | NO_NETWORK_AVAILABLE | | 18 | NO_NETWORK_AVAILABLE |
| 7 | CONFIGURATION_FAILED | | 20 | CLIENT_CERTIFICATE_NOT_YET_VALID |
| 8 | INTERNAL_ERROR | | 21 | CLIENT_CERTIFICATE_EXPIRED |
| 9 | CONNECTION_ERROR | | 22 | SERVER_CERTIFICATE_NOT_YET_VALID |
| 10 | SERVER_NEGOTIATION_FAILED | | 23 | SERVER_CERTIFICATE_EXPIRED |
| 11 | AUTHENTICATION_FAILED | | 24 | SERVER_CERTIFICATE_INVALID |
| 12 | SERVER_CERTIFICATE_INVALID | | | |
| 13 | CLIENT_CERTIFICATE_INVALID | | | |

**A third domain, `IKEv2ProviderDisconnectionErrorDomain`, is not in this
resolver** — it is the IKEv2 *provider extension's own* NSError (per the SDK doc
above), which is why our auth-failure case surfaced *that* domain with code 3
rather than a `…Plugin`/`…IPSec` code. Its codes are defined in
`NEIKEv2Provider.appex`, not the framework.

**Bottom line:** to interpret `VPN.LastCause` / `LastDisconnectError`, branch on
`domain` first, then use the matching table above. The three domains
(`…Plugin`, `…IPSec`, `IKEv2ProviderDisconnectionErrorDomain`) each number their
codes independently — never assume a bare number without its domain. Our live
measurements (7, 20, 21 in the Plugin domain) match the decoded tables exactly.

### Reproducing the extraction

```sh
brew install blacktop/tap/ipsw
CACHE=/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
ipsw dyld extract "$CACHE" \
  /System/Library/Frameworks/NetworkExtension.framework/NetworkExtension \
  --output /tmp/ne_extract
ipsw macho disass /tmp/ne_extract/NetworkExtension \
  --symbol '+[NEVPNConnection createDisconnectErrorWithDomain:code:]'
# then decode the two jump tables' __cfstring targets to keys (see the
# throwaway parser used for this doc). VPN_DISCONNECT_ERROR_* strings + their
# messages also live in
#   NetworkExtension.framework/…/Resources/Localizable.loctable
```



**Symptom:** with two IKEv2 VPNs connected, disconnecting *one* also brings the
*other* down a few seconds later — even though nothing touched the second one.

**Reproduced both directions** (`ares-staging` + the local `test-vpn-…`, both
IKEv2), sampling both VPNs once/second with `vpnutil watch` while streaming
`nesessionmanager` / `neagent` / `com.apple.networkextension` logs:

| Action | The VPN you stopped | The *other* VPN (collateral) |
|--------|---------------------|------------------------------|
| Stop `test-vpn` | `LastCause 1` (clean stop) | `ares-staging` → **`LastCause 7`**, `NEVPNConnectionErrorDomainPlugin` 7, "internal error occurred", stop reason **`Plugin failed`** |
| Stop `ares-staging` | `LastCause 1` (clean stop) | `test-vpn` → **`LastCause 7`**, same domain/code/message, **`Plugin failed`** |

The collateral drop lagged the intentional stop by ~5s (and up to the ~20s
stopping-state timeout when the victim was still mid-negotiation).

**Root cause (from the logs):** both IKEv2 tunnels are hosted by a **single
shared `NEIKEv2Provider` extension process**. In each run every session line and
every `Killing extension, pid <N>` referenced the **same** pid
(e.g. `IKEv2Provider[14403]` served *both* `test-vpn` and `ares-staging`). The
disconnect teardown ends with `nesessionmanager` doing `Killing extension,
pid <N>` — which kills the process hosting the *other* still-active tunnel too.
The surviving session's plugin then can't continue:

```
nesessionmanager: … Killing extension, pid 14403
nesessionmanager: NESM…VPNSession[…:ares-staging:…]: … disconnected with reason Plugin failed
nesessionmanager: … status changed to disconnected, last stop reason Plugin failed
VPN(app):         Last disconnect error for ares-staging changed from "none"
                    to "The VPN session failed because an internal error occurred."
network:          nw_network_agent_remove_from_interface … ipsec1 failed [6: Device not configured]
```

So **`LastCause == 7` / `NEVPNConnectionErrorDomainPlugin` 7 / stop reason
"Plugin failed"** is the fingerprint of *"my extension process was killed out
from under me"* — here caused by another IKEv2 VPN's teardown killing the shared
provider. (The two tunnels do use distinct interfaces — `ipsec0` vs `ipsec1` —
so it is the shared *process*, not a shared interface, that couples them.)

**Implication for the app:** a `LastCause 7` disconnect is **not** a server or
network problem — it is an internal/plugin teardown. If VPNStatus disconnects one
VPN while others are connected, expect the others to report cause 7 and drop. A
mitigation would be to avoid tearing down one IKEv2 session while others are up,
or to auto-reconnect survivors that report cause 7 right after an unrelated
disconnect. (Whether macOS *should* share one process across configs is an Apple
implementation detail; this is observed behavior on the tested OS.)

## Behavior worth knowing (for the app)

- A session stuck **Connecting** against an unreachable server retries
  indefinitely; the `VPN` sub-dict is empty (no cause yet). `ne_session_stop`
  aborts the attempt and *then* records `LastCause = 20` +
  `LastDisconnectError` (server not responding). This matches the app's use of
  `ne_session_stop` (not `ne_session_cancel`) to cancel a Connecting attempt.
- A **hard** server death is only noticed once traffic (or DPD, ~30s here) tries
  to cross the tunnel — status can read Connected for many seconds after the
  server is gone if the link is idle. A **graceful** server stop (IKE DELETE) is
  noticed within ~1s.
- To surface a human-readable failure reason in the UI, prefer
  `LastDisconnectError.userInfo[NSLocalizedDescription]` when present; fall back
  to a `(domain, LastCause)` lookup only if the error object is absent.

## How to reproduce

All against `test/target_vpn/` with the profile connected:

```sh
DUMP=test/vpnutil/vpnutil          # build: see test/vpnutil/README.md
DEC=test/vpnutil/decode_lasterror  # clang -fobjc-arc -framework Foundation \
                                   #   -framework SystemConfiguration -framework NetworkExtension \
                                   #   -o decode_lasterror decode_lasterror.m

# Clean user stop → LastCause 1, no error object:
/opt/homebrew/bin/vpnutil stop  "<name>"; "$DUMP" dump "<name>"; "$DEC" "<name>"

# Server not responding → LastCause 20 (Plugin domain 20).
#   Cert-safe way (keeps PKI/profile): kill the daemon inside the VM:
limactl shell vpn-target sudo systemctl stop strongswan     # then drive tunnel traffic
#   ...capture..., then:
limactl shell vpn-target sudo systemctl start strongswan

# Server aborts session → LastCause 21 (Plugin domain 21):
#   systemctl stop strongswan while Connected sends an IKE DELETE (graceful) →
#   observed as 21 within ~1s (vs 20 for a hard kill / idle DPD timeout).

# Auth failure → LastCause 3 (IKEv2ProviderDisconnectionErrorDomain 3):
#   Reversibly point the server's remote.id at a bogus identity, reload, connect:
limactl shell vpn-target sudo sed -i 's/^\( *id = \).*vpn.local/\1nonexistent.vpn.local/' \
  /etc/swanctl/swanctl.conf && limactl shell vpn-target sudo swanctl --load-all
#   ...connect + capture..., then restore the id and reload.

# Multi-VPN collateral kill → the OTHER VPN gets LastCause 7 (Plugin domain 7):
#   Connect two IKEv2 VPNs, then watch BOTH once/second while stopping one:
"$DUMP" watch ares-staging test-vpn-<stamp> &   # full dump of both every 1s
/opt/homebrew/bin/vpnutil stop ares-staging     # the survivor drops ~5s later, cause 7
#   `watch` takes any number of profile names and dumps each every second to
#   stdout. For a fast cadence cap the probed selectors:
#   VPNUTIL_MAX_INFO=2 VPNUTIL_INFO_TIMEOUT=0.2 "$DUMP" watch <name> <name> …
```

> **Do not `./vpn-target.sh restart` / `stop`+`start` mid-test unless you mean to
> reboot the guest.** With the persisted-build-stamp fix the certs/profile now
> survive a reboot, but the fastest cert-safe way to make the server "go away"
> is `systemctl stop/start strongswan` inside the VM (see
> `test/target_vpn/README.md`).

## Open items / not yet mapped

- **Live-measured** causes so far: 1, 7 (collateral kill), and 3 (in the
  IKEv2-provider domain), plus 20 and 21. The **full `…Plugin` and `…IPSec`
  code→key tables are now known** (decoded from the framework — see "Complete
  private code→key tables"), so the remaining work is just confirming that
  triggering each condition yields the code the table predicts (e.g. connect
  with an expired client cert → expect `…Plugin` 27). No longer a mapping
  unknown, only validation.
- **`IKEv2ProviderDisconnectionErrorDomain` codes are still unmapped** — that
  domain is *not* in the framework resolver (it is the IKEv2 provider
  extension's own NSError). Its code set lives in
  `NEIKEv2Provider.appex/Contents/MacOS/NEIKEv2Provider` and would need the same
  disassembly treatment there. We only know code 3 empirically (server sent
  `N(AUTH_FAILED)`); whether 3 is specifically "auth" or a general negotiation
  bucket is unconfirmed.
- The numeric `SessionState` / `NEStatus` private enumerations beyond the four
  resting states here were not fully enumerated (the richer *session-manager*
  state names — `NESMVPNSessionState*` — are listed above, but the mapping from
  those to the small numeric `SessionState`/`NEStatus` values is not 1:1 and
  wasn't decoded).
