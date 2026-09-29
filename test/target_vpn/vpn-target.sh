#!/bin/bash
# vpn-target.sh -- manage the local test IKEv2 VPN target VM (Lima, bridged).
#
# Subcommands:
#   start        Create/start the VM and provision the IKEv2 server.
#   stop         Stop the VM (VPN goes away -- lets you test start/stop control).
#   restart      Stop then start.
#   status       Show VM status + the server's swanctl connection list + LAN IP.
#   ip           Print the VM's bridged LAN IP (the VPN server address).
#   mobileconfig Copy the generated .mobileconfig out of the VM to ./out/.
#   install      start + mobileconfig + open the profile in System Settings.
#   logs         Tail the in-VM provisioning log.
#   shell        Open a shell in the VM.
#   delete       Stop and delete the VM entirely.
#
# WHY LIMA BRIDGED: bridged networking gives the VM a real LAN IP; the VPN binds
# UDP 500/4500 there, NOT on the Mac. No host port forwarding is used, so the
# Mac's 500/4500 stay free and the VPN keeps working. Do NOT switch to docker or
# any port-forwarding scheme.

set -euo pipefail

NAME="vpn-target"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
INSTALL_DIR="$SCRIPT_DIR/install"
YAML="$SCRIPT_DIR/vpn-target.yaml"
OUT_DIR="$SCRIPT_DIR/out"

die() { echo "vpn-target: $*" >&2; exit 1; }

# The provisioner stamps a unique per-build display name and writes it into the
# VM (~/vpn_target_display_name). Read it back so we always operate on the
# current build's mobileconfig, not a stale hardcoded name.
display_name() {
  local dn
  dn="$(limactl shell "$NAME" sh -c 'cat ~/vpn_target_display_name' 2>/dev/null | tr -d '[:space:]')"
  [ -n "$dn" ] || dn="VPNStatusTestTarget"
  echo "$dn"
}

profile_name() {
  local pn
  pn="$(limactl shell "$NAME" sh -c 'cat ~/vpn_target_profile_name' 2>/dev/null | tr -d '[:space:]')"
  echo "$pn"
}

need_lima() {
  command -v limactl >/dev/null 2>&1 || die "limactl not found (brew install lima)"
}

check_bridged_ready() {
  # socket_vmnet + sudoers must exist for bridged mode.
  [ -x /opt/socket_vmnet/bin/socket_vmnet ] || \
    die "socket_vmnet missing. Run: brew install socket_vmnet && limactl sudoers | sudo tee /etc/sudoers.d/lima"
  sudo grep -q "vmnet-mode=bridged" /etc/sudoers.d/lima 2>/dev/null || \
    die "bridged sudoers entry missing. Run: limactl sudoers | sudo tee /etc/sudoers.d/lima"
}

vm_exists() { limactl list -q 2>/dev/null | grep -qx "$NAME"; }

vm_running() { [ "$(limactl list "$NAME" --format '{{.Status}}' 2>/dev/null)" = "Running" ]; }

get_ip() {
  vm_running || return 1
  limactl shell "$NAME" cat '/tmp/vpn_target_ip' 2>/dev/null | tr -d '[:space:]'
}

cmd_start() {
  need_lima
  check_bridged_ready
  if vm_exists; then
    vm_running && { echo "vpn-target: already running"; cmd_status; return; }
    echo "vpn-target: starting existing VM..."
    limactl start "$NAME"
  else
    echo "vpn-target: creating VM (bridged) and provisioning IKEv2..."
    limactl start --name="$NAME" --tty=false \
      --set ".mounts[0].location = \"$INSTALL_DIR\"" \
      "$YAML"
  fi
  echo
  cmd_status
}

cmd_stop() {
  need_lima
  vm_exists || die "VM '$NAME' does not exist"
  echo "vpn-target: stopping VM (VPN server goes offline)..."
  limactl stop "$NAME"
}

cmd_restart() { cmd_stop || true; cmd_start; }

cmd_status() {
  need_lima
  vm_exists || { echo "vpn-target: VM does not exist (run: $0 start)"; return; }
  limactl list "$NAME"
  if vm_running; then
    local ip; ip="$(get_ip || true)"
    echo "VPN server IP: ${ip:-<unknown>}"
    echo "VPN profile name: $(profile_name)"
    echo "swanctl connections:"
    limactl shell "$NAME" sudo swanctl --list-conns 2>/dev/null | sed 's/^/  /' || \
      echo "  (strongSwan not ready yet)"
  fi
}

cmd_ip() {
  need_lima
  local ip; ip="$(get_ip || true)"
  [ -n "$ip" ] || die "VM not running or IP not ready"
  echo "$ip"
}

cmd_mobileconfig() {
  need_lima
  vm_running || die "VM not running (run: $0 start)"
  mkdir -p "$OUT_DIR"
  local dn; dn="$(display_name)"
  local dst="$OUT_DIR/$dn.mobileconfig"
  echo "vpn-target: copying mobileconfig ($dn) from VM..." >&2
  local remote_home; remote_home="$(limactl shell "$NAME" sh -c 'echo $HOME')"
  limactl copy "$NAME:$remote_home/$dn.mobileconfig" "$dst"
  echo "vpn-target: wrote $dst" >&2
  echo "$dst"
}

cmd_install() {
  cmd_start
  local cfg; cfg="$(cmd_mobileconfig | tail -1)"
  local dl="$HOME/Downloads/$(basename "$cfg")"
  cp "$cfg" "$dl"
  echo "vpn-target: copied to $dl"
  echo "vpn-target: current VPN profile name: $(profile_name)"
  echo "vpn-target: remove any OLDER VPNStatusTestTarget-* profile in System Settings"
  echo "            > General > Device Management, then approve this one (p12 pass: password)."
  echo "vpn-target: opening $dl in System Settings..."
  open "$dl"
}

cmd_logs() {
  need_lima
  vm_running || die "VM not running"
  limactl shell "$NAME" sudo tail -n 200 -f /tmp/install.log
}

cmd_shell() {
  need_lima
  vm_running || die "VM not running"
  limactl shell "$NAME"
}

cmd_delete() {
  need_lima
  vm_exists || { echo "vpn-target: nothing to delete"; return; }
  echo "vpn-target: deleting VM '$NAME'..."
  limactl stop "$NAME" 2>/dev/null || true
  limactl delete "$NAME"
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  start)        cmd_start ;;
  stop)         cmd_stop ;;
  restart)      cmd_restart ;;
  status)       cmd_status ;;
  ip)           cmd_ip ;;
  mobileconfig) cmd_mobileconfig ;;
  install)      cmd_install ;;
  logs)         cmd_logs ;;
  shell)        cmd_shell ;;
  delete)       cmd_delete ;;
  ""|-h|--help) usage ;;
  *)            die "unknown command '$1' (run: $0 --help)" ;;
esac
