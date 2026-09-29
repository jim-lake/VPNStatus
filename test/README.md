# Test configuration profiles

Manual-testing `.mobileconfig` profiles for VPNStatus. These install **real**
`NEConfiguration` objects so you can see how the app enumerates and filters
them, without needing a working VPN server.

Both use `192.0.2.1` (RFC 5737 TEST-NET-1), a reserved, unroutable address, so
neither profile ever actually connects or changes your networking.

| Profile | Payload type | Has VPN payload? | Expected in VPNStatus menu? |
|---|---|---|---|
| `VPNStatusTest-NonConnectingVPN.mobileconfig` | `com.apple.vpn.managed` (IKEv2) | Yes | **Yes** — shows as `VPNStatus Test - Unreachable`, connect attempts time out |
| `VPNStatusTest-EncryptedDNS.mobileconfig` | `com.apple.dnsSettings.managed` (DoH) | No (`-VPN` is nil) | **No** — filtered out by type in `ACNEServicesManager -processConfigurations:` |

The Encrypted DNS profile reproduces the original bug (a non-VPN configuration
like "Google Public DNS Encrypted DNS over HTTPS" showing up as a VPN) and
verifies the type-based filter now hides it.

## Install / verify / remove

```bash
# Install (then approve in System Settings > General > VPN & Device Management):
open test/VPNStatusTest-NonConnectingVPN.mobileconfig
open test/VPNStatusTest-EncryptedDNS.mobileconfig

# Both NEConfigurations are visible to vpnutil regardless of type:
vpnutil list

# The VPNStatus menu should list only the VPN profile, not the DNS one.

# Remove:
sudo profiles remove -identifier org.timac.VPNStatus.test.unreachable-vpn
sudo profiles remove -identifier org.timac.VPNStatus.test.encrypted-dns
```

The automated equivalent of the filter check lives in
`VPNStatusTests/ACNEServicesManagerFilterTests.m`, which drives
`-processConfigurations:` with stub configurations and asserts the non-VPN one
is dropped.
