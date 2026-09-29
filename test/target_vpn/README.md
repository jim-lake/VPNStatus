# test/target_vpn — local IKEv2 VPN target for exercising VPNStatus

A **real** IKEv2 (strongSwan) VPN server running in a Lima VM on your Mac, so you
can install its `.mobileconfig`, connect/disconnect it from VPNStatus, and test
the app against a live NetworkExtension VPN — then start/stop the VM to control
whether the server is reachable.

It stands up Ubuntu + strongSwan (`swanctl`) with a single-use ECDSA easy-rsa
PKI and generates a matching macOS `.mobileconfig`. The server is addressed by
the VM's **IP** (its bridged LAN address); the server cert carries that IP as a
SAN, and each client cert carries a DNS SAN that the swanctl `remote.id` and the
mobileconfig `LocalIdentifier` both match.

## Why Lima with BRIDGED networking (not Docker / port forwarding)

IKEv2 uses **UDP 500 and 4500**. If those ports are forwarded/occupied on the
Mac, the VPN breaks. Docker (and Lima's default user-mode networking) forward
guest ports onto the host, which would grab host 500/4500 and stop the VPN
working.

Instead this uses Lima **bridged** networking: the VM gets its own DHCP address
on your LAN (e.g. `192.168.1.222`) and strongSwan binds 500/4500 **on that IP**.
Nothing is forwarded from the Mac, so host 500/4500 stay free. The Lima config
also explicitly disables all guest→host port forwarding (`portForwards` /
`ignore: true`) — on Lima 2.x this needs rules for both `0.0.0.0` and
`127.0.0.1` listeners, otherwise the hostagent still binds host 500/4500.

## Requirements

- [Lima](https://lima-vm.io) ≥ 2.0 (`brew install lima`)
- `socket_vmnet` for bridged mode, plus the lima sudoers entry:
  ```sh
  brew install socket_vmnet
  limactl sudoers | sudo tee /etc/sudoers.d/lima
  ```
  The bridged network must be defined in `~/.lima/_config/networks.yaml` as
  `bridged: { mode: bridged, interface: en0 }` (Lima ships this by default;
  change `en0` if your LAN interface differs).

## Usage

```sh
cd test/target_vpn

./vpn-target.sh start          # create/boot the VM + provision the IKEv2 server
./vpn-target.sh mobileconfig   # copy the .mobileconfig to ./out/
./vpn-target.sh install        # start + fetch + open the profile in System Settings
./vpn-target.sh status         # VM status + swanctl connections + server IP
./vpn-target.sh ip             # print the VM's bridged LAN IP
./vpn-target.sh stop           # stop the VM (server goes offline)
./vpn-target.sh restart        # stop + start
./vpn-target.sh logs           # tail the in-VM provisioning log
./vpn-target.sh shell          # shell into the VM
./vpn-target.sh delete         # destroy the VM
```

### Installing the profile

1. `./vpn-target.sh install` (or `mobileconfig` then open `out/*.mobileconfig`).
2. System Settings → General → Device Management → **remove any older
   `VPNStatusTestTarget-*` profile first**, then approve the new one.
   The client cert PKCS#12 password is `password`.
3. The VPN now appears in macOS and in VPNStatus.

One split-tunnel profile is installed, with a **unique per-build name**:

| Profile                    | Tunnel       | Routes               |
|----------------------------|--------------|----------------------|
| `test-vpn-<YYYYMMDDHHMMSS>` | split tunnel | `10.199.0.0/16` only |

The route doesn't cover your real LAN, so connecting won't cut off
SSH/reachability to the VM itself. (No full-tunnel profile — a VPN test target
never needs to route all traffic.)

### Why the name changes every build

Each provision stamps the current timestamp into the profile display name, the
macOS VPN entry, the client identity/CN, and the keychain label
(`VPNStatusTestTarget-<stamp>` / `test-vpn-<stamp>`). This is deliberate:
rebuilding regenerates the single-use CA, and macOS keeps the **first**-installed
identity for a given name — so reusing a name silently pins a stale client cert
whose CA the rebuilt server no longer trusts, and IKE_AUTH fails with
`no trusted public key found`. A fresh name every build guarantees you're always
installing/using the latest cert, and old profiles can just be deleted. Run
`./vpn-target.sh status` to see the current build's profile name.

## Testing start/stop control

- `./vpn-target.sh stop` takes the server offline. A connected client can no
  longer reach it (good for testing VPNStatus's reconnect/backoff and the
  `Connecting…` state).
- `./vpn-target.sh start` brings it back on the **same** LAN IP (DHCP lease is
  sticky), so the installed profile keeps working. If DHCP ever hands out a
  different IP, re-running provisioning rebuilds the PKI/profile for the new IP
  (the old profile would then need reinstalling).

## Verify real VPN state independently

Use `vpnutil` (Homebrew) — `scutil`/`networksetup` cannot see NE/IKEv2 VPNs:

```sh
vpnutil list                       # shows the current test-vpn-<stamp> entry
vpnutil status "$(./vpn-target.sh status | sed -n 's/^VPN profile name: //p')"
```

On the server side:

```sh
./vpn-target.sh shell
sudo swanctl --list-sas     # active security associations (live connections)
sudo swanctl --list-conns   # loaded connection definitions
```

## Files

- `vpn-target.yaml` — Lima config: Ubuntu 26.04, bridged en0, all port
  forwarding disabled, mounts `install/` at `/opt/vpn-install`, runs
  `provision.sh`.
- `vpn-target.sh` — the management CLI above.
- `install/provision.sh` — in-VM: detects the bridged IP, installs strongSwan,
  enables IP forwarding, runs `ike-setup.sh`.
- `install/ike-setup.sh` — builds the ECDSA easy-rsa PKI, writes
  `swanctl.conf`, and drives the mobileconfig generator. Server cert uses an
  `IP:` SAN; client certs use a `DNS:` SAN matched by the swanctl `remote.id`
  and the mobileconfig `LocalIdentifier`.
- `install/make-mobileconfig.py` — builds the `.mobileconfig` (one IKEv2 payload
  + one PKCS#12 payload per profile).
- `install/vars-ike`, `install/strongswan.conf` — easy-rsa ECDSA vars and the
  charon config (`uniqueids = no`).
- `out/` — generated `.mobileconfig` lands here (git-ignored).

## How authentication is wired (why it connects)

Mutual certificate auth. Both ends must agree on identities that appear in the
certs, or strongSwan rejects the client with `no trusted ECDSA public key found`
→ `AUTH_FAILED`, even when the CA/cert chain is otherwise valid.

- **CA:** one self-signed ECDSA easy-rsa CA. Its cert is embedded in the client
  PKCS#12 (so it installs into the macOS keychain) **and** placed in the server's
  `/etc/swanctl/x509ca/ca.crt`. The same CA validates both the server cert (Mac
  side) and the client cert (server side). The CA key is shredded after signing.
  It has **no name constraints**.
- **Server identity:** the server cert has `subjectAltName = IP:<vm-ip>`. The
  mobileconfig sets `RemoteAddress` and `RemoteIdentifier` to that IP, so macOS
  matches the server cert by IP.
- **Client identity:** the client cert has `subjectAltName = DNS:<client_id>`
  where `client_id = <user>-ike-<profile>.vpn.local`. The swanctl connection's
  `remote.id` is that same `client_id`, and the mobileconfig `LocalIdentifier`
  (the `IDi` macOS sends) is that same `client_id`. All three must match — a
  bare CN with no SAN does **not** work.

## Troubleshooting

**`no trusted ECDSA public key found` / `AUTH_FAILED` on the server**
The client cert's identity doesn't match what the server expects, or the Mac is
presenting a stale cert. Check three things line up:
```sh
# 1) client cert DNS SAN on the VM
./vpn-target.sh shell
sudo openssl x509 -in /etc/swanctl/easy-rsa/pki/issued/<client>.crt -noout -ext subjectAltName
sudo grep -A3 'remote {' /etc/swanctl/swanctl.conf     # remote.id
# 2) mobileconfig LocalIdentifier on the Mac
plutil -p out/*.mobileconfig | grep LocalIdentifier
```
If they differ, or an **older** profile is still installed, remove every
`VPNStatusTestTarget-*` profile in System Settings → General → Device
Management, then `./vpn-target.sh install` and connect the new one. macOS keeps
the first-installed identity for a given name, so reusing a name after a CA
rebuild silently pins a stale cert — which is exactly why every build gets a
unique stamped name.

**Verbose server-side IKE log for one attempt**
```sh
./vpn-target.sh logs                       # provisioning log
limactl shell vpn-target sudo journalctl -u strongswan -f
```

**VPN can't be reached at all** — confirm the VM is up and on the LAN:
```sh
./vpn-target.sh status          # shows Running + server IP
ping "$(./vpn-target.sh ip)"    # reachable over bridged
```
If host UDP 500/4500 ever show a `limactl` listener (`lsof -nP -iUDP:500
-iUDP:4500`), the port-forwarding suppression in `vpn-target.yaml` regressed —
those ports must stay free for the VPN to work.

## Verified

Confirmed end to end: profile installs on macOS, VPNStatus connects the VM's
IKEv2 VPN (server-side `swanctl --list-sas` shows an ESTABLISHED SA), and
`./vpn-target.sh stop` / `start` toggles reachability so reconnect behavior can
be exercised.
