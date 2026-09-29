#!/bin/bash
# provision.sh -- runs inside the Lima VM as root (system provisioning). Installs
# strongSwan and generates the IKEv2 server + client PKI + mobileconfig, using
# the VM's BRIDGED LAN IP as the VPN server address.
#
# The bridged interface gives the VM its own DHCP address on the host LAN, so the
# VPN listens on UDP 500/4500 on that address directly -- nothing is forwarded
# from the macOS host, so host ports 500/4500 stay free and the VPN keeps working.

set -euo pipefail
trap 'echo "provision: FAILED at line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR

VERBOSE_LOG=/tmp/install.log
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# The unprivileged Lima user owns the generated mobileconfig / p12 files so they
# land in a home dir the host mount can read back.
INSTALL_USER="${LIMA_USER:-$(ls /home | head -1)}"
INSTALL_USER_HOME="$(eval echo ~"$INSTALL_USER")"

# Every build gets a unique stamp so the profile, the macOS VPN entry, the
# client identity/CN, and the keychain label are all NEW each time. This avoids
# stale certs lingering in the login keychain from a previous build (macOS keeps
# the first-installed identity for a given name, which silently breaks IKE_AUTH
# after a CA rebuild). A fresh name means you always know the installed profile
# is the latest, and old ones can simply be deleted.
BUILD_STAMP="$(date +%Y%m%d%H%M%S)"
VPN_DISPLAY_NAME="VPNStatusTestTarget-$BUILD_STAMP"
# One split-tunnel profile that routes only the test net (10.199.0.0/16). The
# route doesn't touch the host LAN, so connecting won't disrupt SSH into the VM.
PROFILE_VPN="test-vpn-$BUILD_STAMP"
echo "provision: build stamp = $BUILD_STAMP (profile=$PROFILE_VPN)"

echo "provision: install user = $INSTALL_USER ($INSTALL_USER_HOME)"

# --- Find the bridged interface's IPv4 address (NOT the user-mode lima0/eth0). ---
# Lima's bridged NIC is a second interface; the default route still goes out the
# user-mode NIC, so pick the interface that has a routable LAN address and is not
# the lima slirp 192.168.5.0/24 user network.
detect_bridged_ip() {
  local ip
  for ifc in $(ls /sys/class/net | grep -Ev '^(lo|docker|veth)'); do
    ip=$(ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -z "$ip" ] && continue
    # Skip lima's user-mode slirp network (192.168.5.x).
    case "$ip" in
      192.168.5.*) continue ;;
    esac
    echo "$ip"
    return 0
  done
  return 1
}

VPN_HOST=""
for _ in $(seq 1 30); do
  VPN_HOST="$(detect_bridged_ip || true)"
  [ -n "$VPN_HOST" ] && break
  sleep 1
done
[ -n "$VPN_HOST" ] || { echo "provision: could not find a bridged LAN IP" >&2; ip -4 -o addr show >&2; exit 1; }
echo "provision: bridged VPN_HOST = $VPN_HOST"

# Record the IP so the host helper can read it back.
echo "$VPN_HOST" > /tmp/vpn_target_ip
cp /tmp/vpn_target_ip "$INSTALL_USER_HOME/vpn_target_ip"
chown "$INSTALL_USER" "$INSTALL_USER_HOME/vpn_target_ip"

# Record the stamped names so the host helper knows the current build's
# mobileconfig filename / profile / VPN entry name.
echo "$VPN_DISPLAY_NAME" > "$INSTALL_USER_HOME/vpn_target_display_name"
echo "$PROFILE_VPN" > "$INSTALL_USER_HOME/vpn_target_profile_name"
chown "$INSTALL_USER" "$INSTALL_USER_HOME/vpn_target_display_name" "$INSTALL_USER_HOME/vpn_target_profile_name"

IKE_PROFILES="$PROFILE_VPN 10.199.10.0/24 - 10.199.0.0/16 no"

export DEBIAN_FRONTEND=noninteractive
echo "provision: apt update"
apt-get update >>"$VERBOSE_LOG" 2>&1
echo "provision: apt install strongSwan + easy-rsa"
apt-get install -y \
  strongswan strongswan-swanctl libcharon-extra-plugins libstrongswan-extra-plugins \
  libstrongswan-standard-plugins easy-rsa openssl python3 >>"$VERBOSE_LOG" 2>&1

echo "provision: enable IP forwarding"
cat > /etc/sysctl.d/98-vpn-target.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -q --system >>"$VERBOSE_LOG" 2>&1

echo "provision: run ike-setup.sh"
INSTALL_USER="$INSTALL_USER" INSTALL_USER_HOME="$INSTALL_USER_HOME" \
  SCRIPT_DIR="$SCRIPT_DIR" VPN_HOST="$VPN_HOST" \
  VPN_DISPLAY_NAME="$VPN_DISPLAY_NAME" IKE_PROFILES="$IKE_PROFILES" \
  VERBOSE_LOG="$VERBOSE_LOG" \
  bash "$SCRIPT_DIR/ike-setup.sh"

echo "provision: DONE. VPN server at $VPN_HOST"
echo "provision: mobileconfig = $INSTALL_USER_HOME/$VPN_DISPLAY_NAME.mobileconfig"
swanctl --list-conns 2>/dev/null | sed 's/^/provision:   /' || true
