#!/bin/bash
# ike-setup.sh -- IKEv2 / strongSwan PKI + config generator for the local test
# VPN target VM.
#
# The test server is reached by IP (the VM's bridged LAN address), not a DNS
# name: the server cert carries an IP: SAN and the generated mobileconfig
# RemoteAddress/RemoteIdentifier is that IP. Each client cert carries a DNS: SAN
# equal to its client_id, and the swanctl remote.id plus the mobileconfig
# LocalIdentifier use that same value, so the peer identity matches on both ends.
#
# One profile per line, five space-separated fields ("-" = empty field):
#   name  pool_v4  pool_v6  routes  full_tunnel
#
# Required env: INSTALL_USER INSTALL_USER_HOME SCRIPT_DIR VPN_HOST
#               VPN_DISPLAY_NAME IKE_PROFILES
#   VPN_HOST here is the VM's bridged IPv4 address.
# Optional env: VERBOSE_LOG

set -euo pipefail
trap 'echo "ike-setup: FAILED at line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR

: "${INSTALL_USER:?}"; : "${INSTALL_USER_HOME:?}"; : "${SCRIPT_DIR:?}"
: "${VPN_HOST:?}"; : "${VPN_DISPLAY_NAME:?}"; : "${IKE_PROFILES:?}"
VERBOSE_LOG="${VERBOSE_LOG:-/tmp/install.log}"

EASYRSA_DIR=/etc/swanctl/easy-rsa
CERT_CN_PREFIX="$INSTALL_USER-ike"
P12_PASS="password"

SW_CA=/etc/swanctl/x509ca/ca.crt
SW_SRV=/etc/swanctl/x509/server.crt
SW_KEY=/etc/swanctl/private/server.key
MOBILECONFIG="$INSTALL_USER_HOME/$VPN_DISPLAY_NAME.mobileconfig"

SERVER_PUBKEY_ALGO="id-ecPublicKey"

PROF_NAMES=(); PROF_POOL4=(); PROF_POOL6=(); PROF_ROUTES=(); PROF_FULL=()
undash() { [ "$1" = "-" ] && echo "" || echo "$1"; }
while read -r name pool4 pool6 routes full; do
  [ -z "$name" ] && continue
  PROF_NAMES+=("$name")
  PROF_POOL4+=("$(undash "$pool4")")
  PROF_POOL6+=("$(undash "$pool6")")
  PROF_ROUTES+=("$(undash "$routes")")
  PROF_FULL+=("$(undash "$full")")
done <<< "$IKE_PROFILES"

[ "${#PROF_NAMES[@]}" -gt 0 ] || { echo "ike-setup: IKE_PROFILES is empty" >&2; exit 1; }
for i in "${!PROF_NAMES[@]}"; do
  [ -n "${PROF_POOL4[$i]}" ] || { echo "ike-setup: profile ${PROF_NAMES[$i]} missing pool_v4" >&2; exit 1; }
done

cert_cn()   { echo "$CERT_CN_PREFIX-$1"; }
# Client identity is an FQDN-shaped string carried as a DNS SAN on the client
# cert. The host part is arbitrary for a local test target; using the profile
# name keeps it unique per build. This SAN is what the server matches remote.id
# against and what macOS sends as IDi.
client_id() { echo "$CERT_CN_PREFIX-$1.vpn.local"; }
client_p12(){ echo "$INSTALL_USER_HOME/$(cert_cn "$1").p12"; }

mkdir -p /etc/swanctl/x509 /etc/swanctl/x509ca /etc/swanctl/private

build_client_pki() {
  rm -rf "$EASYRSA_DIR"
  make-cadir "$EASYRSA_DIR" >>"$VERBOSE_LOG" 2>&1
  cp "$SCRIPT_DIR/vars-ike" "$EASYRSA_DIR/vars"
  ( cd "$EASYRSA_DIR" && ./easyrsa init-pki >>"$VERBOSE_LOG" 2>&1 )
  # No CA name constraints: a local IP-addressed test target doesn't need one,
  # and a stray IP constraint would reject the DNS-SAN client identity.
  ( cd "$EASYRSA_DIR" && ./easyrsa --batch build-ca nopass >>"$VERBOSE_LOG" 2>&1 )

  for name in "${PROF_NAMES[@]}"; do
    cn="$(cert_cn "$name")"
    ( cd "$EASYRSA_DIR" && ./easyrsa --batch gen-req "$cn" nopass >>"$VERBOSE_LOG" 2>&1 )
    # Client cert carries a DNS SAN = client_id, so the server's remote.id and
    # the IDi macOS sends both match the cert identity.
    ( cd "$EASYRSA_DIR" && EASYRSA_EXTRA_EXTS="subjectAltName=DNS:$(client_id "$name")" \
        ./easyrsa --batch sign-req client "$cn" >>"$VERBOSE_LOG" 2>&1 )
  done

  ( cd "$EASYRSA_DIR" && ./easyrsa --batch gen-req "server" nopass >>"$VERBOSE_LOG" 2>&1 )
  # Server SAN is the IP; macOS matches RemoteIdentifier against this.
  ( cd "$EASYRSA_DIR" && EASYRSA_EXTRA_EXTS="subjectAltName=IP:$VPN_HOST" \
      ./easyrsa --batch sign-req server "server" >>"$VERBOSE_LOG" 2>&1 )
  cp "$EASYRSA_DIR/pki/issued/server.crt" "$SW_SRV"
  cp "$EASYRSA_DIR/pki/private/server.key" "$SW_KEY"
  chmod 600 "$SW_KEY"

  shred -u -z "$EASYRSA_DIR/pki/private/ca.key"
  cp "$EASYRSA_DIR/pki/ca.crt" "$SW_CA"

  for name in "${PROF_NAMES[@]}"; do
    cn="$(cert_cn "$name")"; p12="$(client_p12 "$name")"
    openssl pkcs12 -export -legacy \
      -inkey "$EASYRSA_DIR/pki/private/$cn.key" -in "$EASYRSA_DIR/pki/issued/$cn.crt" \
      -certfile "$EASYRSA_DIR/pki/ca.crt" \
      -name "$VPN_DISPLAY_NAME $name" -passout pass:"$P12_PASS" -out "$p12" >>"$VERBOSE_LOG" 2>&1
    chown "$INSTALL_USER" "$p12"
  done
}

client_pki_exists() {
  local out name
  for out in "$SW_CA" "$SW_SRV" "$SW_KEY"; do
    [ -s "$out" ] || return 1
  done
  for name in "${PROF_NAMES[@]}"; do
    [ -s "$(client_p12 "$name")" ] || return 1
  done
  # Rebuild the PKI if the server cert's IP SAN no longer matches VPN_HOST
  # (the bridged DHCP lease can change between runs).
  openssl x509 -in "$SW_SRV" -noout -text 2>/dev/null | grep -q "IP Address:$VPN_HOST" || return 1
  openssl x509 -in "$SW_CA" -noout -text 2>/dev/null | grep -q "Public Key Algorithm: $SERVER_PUBKEY_ALGO" || return 1
  openssl x509 -in "$SW_SRV" -noout -text 2>/dev/null | grep -q "Public Key Algorithm: $SERVER_PUBKEY_ALGO" || return 1
  return 0
}

# ---- swanctl.conf generation ----

PROP_IKE="aes256gcm16-aes192gcm16-aes128gcm16-aes256ccm16-aes192ccm16-aes128ccm16-chacha20poly1305-prfsha256-prfsha384-prfsha512-prfaesxcbc-prfaescmac-ecp256-ecp384-ecp521-ecp256bp-ecp384bp-ecp512bp-x25519-x448-modp3072-modp4096-modp6144-modp8192-modp2048, aes256-aes192-aes128-sha256-sha384-sha512-aesxcbc-aescmac-prfsha256-prfsha384-prfsha512-prfaesxcbc-prfaescmac-ecp256-ecp384-ecp521-ecp256bp-ecp384bp-ecp512bp-x25519-x448-modp3072-modp4096-modp6144-modp8192-modp2048"
PROP_ESP="aes256gcm16-aes192gcm16-aes128gcm16-chacha20poly1305-ecp256-ecp384-ecp521-x25519-x448-modp3072-modp4096-modp2048, aes256-aes192-aes128-sha256-sha384-sha512-aesxcbc-ecp256-ecp384-ecp521-x25519-x448-modp3072-modp4096-modp2048"

profile_local_ts() {
  local i="$1"
  if [ "${PROF_FULL[$i]}" = "yes" ]; then
    echo "0.0.0.0/0, ::/0"
  else
    echo "${PROF_ROUTES[$i]//,/, }"
  fi
}

profile_pools() {
  local i="$1" name="${PROF_NAMES[$1]}" pools
  pools="pool-$name-v4"
  [ -n "${PROF_POOL6[$i]}" ] && pools="$pools, pool-$name-v6"
  echo "$pools"
}

write_swanctl_conf() {
  {
    echo "connections {"
    for i in "${!PROF_NAMES[@]}"; do
      cat <<EOF
    ikev2-${PROF_NAMES[$i]} {
        version = 2
        proposals = $PROP_IKE
        rekey_time = 0
        reauth_time = 0
        pools = $(profile_pools "$i")
        fragmentation = yes
        dpd_delay = 30s
        send_cert = always

        local {
            auth = pubkey
            certs = server.crt
            id = $VPN_HOST
        }
        remote {
            auth = pubkey
            cacerts = ca.crt
            id = $(client_id "${PROF_NAMES[$i]}")
        }
        children {
            net {
                local_ts = $(profile_local_ts "$i")
                esp_proposals = $PROP_ESP
                rekey_time = 0
                dpd_action = clear
            }
        }
    }

EOF
    done
    echo "}"
    echo
    echo "pools {"
    for i in "${!PROF_NAMES[@]}"; do
      name="${PROF_NAMES[$i]}"
      if [ "${PROF_FULL[$i]}" = "yes" ]; then
        cat <<EOF
    pool-$name-v4 {
        addrs = ${PROF_POOL4[$i]}
        dns = 8.8.8.8, 8.8.4.4
    }
EOF
      else
        cat <<EOF
    pool-$name-v4 {
        addrs = ${PROF_POOL4[$i]}
    }
EOF
      fi
      if [ -n "${PROF_POOL6[$i]}" ]; then
        cat <<EOF
    pool-$name-v6 {
        addrs = ${PROF_POOL6[$i]}
    }
EOF
      fi
    done
    echo "}"
  } > /etc/swanctl/swanctl.conf
}

write_config_and_profile() {
  write_swanctl_conf
  mkdir -p /etc/strongswan.d
  cp "$SCRIPT_DIR/strongswan.conf" /etc/strongswan.d/vpn-target.conf
  if [ -f /etc/strongswan.d/charon/resolve.conf ]; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*load[[:space:]]*=.*/    load = no/' /etc/strongswan.d/charon/resolve.conf
  fi

  local args=()
  for i in "${!PROF_NAMES[@]}"; do
    name="${PROF_NAMES[$i]}"
    args+=(--profile "$name:$(client_p12 "$name"):$(client_id "$name"):${PROF_FULL[$i]:-no}:${PROF_ROUTES[$i]}")
  done
  python3 "$SCRIPT_DIR/make-mobileconfig.py" \
    --vpn-host "$VPN_HOST" --p12-password "$P12_PASS" \
    --display-name "$VPN_DISPLAY_NAME" \
    "${args[@]}" \
    --out "$MOBILECONFIG" >>"$VERBOSE_LOG" 2>&1
  chown "$INSTALL_USER" "$MOBILECONFIG"
}

verify_server_cert_is_ecdsa() {
  openssl x509 -in "$SW_SRV" -noout -text 2>/dev/null | grep -q "Public Key Algorithm: $SERVER_PUBKEY_ALGO" \
    || { echo "ike-setup: server cert is not ECDSA" >&2; exit 1; }
  local cpk kpk
  cpk=$(openssl x509 -in "$SW_SRV" -noout -pubkey 2>/dev/null)
  kpk=$(openssl pkey -in "$SW_KEY" -pubout 2>/dev/null)
  [ -n "$cpk" ] && [ "$cpk" = "$kpk" ] || { echo "ike-setup: server key/cert mismatch" >&2; exit 1; }
  openssl x509 -in "$SW_SRV" -checkend 0 -noout >/dev/null 2>&1 \
    || { echo "ike-setup: server cert expired" >&2; exit 1; }
}

reload_strongswan() {
  systemctl enable strongswan >>"$VERBOSE_LOG" 2>&1 || systemctl enable strongswan-swanctl >>"$VERBOSE_LOG" 2>&1
  systemctl restart strongswan >>"$VERBOSE_LOG" 2>&1 || systemctl restart strongswan-swanctl >>"$VERBOSE_LOG" 2>&1
  swanctl --load-all >>"$VERBOSE_LOG" 2>&1
}

client_pki_exists || build_client_pki
verify_server_cert_is_ecdsa
write_config_and_profile
reload_strongswan
