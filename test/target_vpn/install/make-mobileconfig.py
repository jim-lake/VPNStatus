#!/usr/bin/env python3
# Builds a macOS/iOS .mobileconfig with one IKEv2 VPN payload + one PKCS#12
# payload per profile. Each --profile is self-describing; there is no built-in
# notion of specific profile names here:
#
#   --profile name:p12_path:client_id:full_tunnel:routes
#
#   full_tunnel   "yes" -> send all traffic over the tunnel; else split tunnel
#   routes        comma-separated CIDRs (v4 and/or v6) for the split tunnel;
#                 ignored when full_tunnel=yes
import argparse
import ipaddress
import plistlib
import uuid

NS = uuid.UUID("6b6f2a1e-1c2d-4e3f-8a9b-000000000000")


def _uuid(base_id, name):
    return str(uuid.uuid5(NS, f"{base_id}.{name}")).upper()


def split_routes(routes):
    v4, v6 = [], []
    for c in [r.strip() for r in routes.split(",") if r.strip()]:
        net = ipaddress.ip_network(c, strict=False)
        if net.version == 4:
            v4.append({"DestinationAddress": str(net.network_address),
                       "SubnetMask": str(net.netmask)})
        else:
            v6.append({"DestinationAddress": str(net.network_address),
                       "PrefixLength": net.prefixlen})
    return v4, v6


def ikev2_dict(vpn_host, cert_uuid, client_id, full_tunnel, routes):
    d = {
        "AuthenticationMethod": "Certificate",
        "RemoteAddress": vpn_host,
        "RemoteIdentifier": vpn_host,
        "LocalIdentifier": client_id,
        "ExtendedAuthEnabled": 0,
        "PayloadCertificateUUID": cert_uuid,
        "CertificateType": "ECDSA256",
        "EnablePFS": True,
        "DeadPeerDetectionRate": "Medium",
        "IKESecurityAssociationParameters": {
            "EncryptionAlgorithm": "AES-256-GCM",
            "IntegrityAlgorithm": "SHA2-256",
            "DiffieHellmanGroup": 31,
        },
        "ChildSecurityAssociationParameters": {
            "EncryptionAlgorithm": "AES-256-GCM",
            "IntegrityAlgorithm": "SHA2-256",
            "DiffieHellmanGroup": 31,
        },
    }
    if full_tunnel:
        d["IPv4"] = {"OverridePrimary": 1}
    else:
        v4, v6 = split_routes(routes)
        d["IPv4"] = {"OverridePrimary": 0, "IncludedRoutes": v4}
        if v6:
            d["IPv6"] = {"IncludedRoutes": v6}
    return d


def vpn_payload(base_id, name, vpn_host, cert_uuid, client_id, full_tunnel, routes):
    return {
        "PayloadType": "com.apple.vpn.managed",
        "PayloadVersion": 1,
        "PayloadIdentifier": f"{base_id}.vpn.{name}",
        "PayloadUUID": _uuid(base_id, f"vpn.{name}"),
        "PayloadDisplayName": name,
        "UserDefinedName": name,
        "VPNType": "IKEv2",
        "IKEv2": ikev2_dict(vpn_host, cert_uuid, client_id, full_tunnel, routes),
    }


def cert_payload(base_id, display_name, name, p12_path, password):
    with open(p12_path, "rb") as fh:
        p12_data = fh.read()
    return {
        "PayloadType": "com.apple.security.pkcs12",
        "PayloadVersion": 1,
        "PayloadIdentifier": f"{base_id}.cert.{name}",
        "PayloadUUID": _uuid(base_id, f"cert.{name}"),
        "PayloadDisplayName": f"{display_name} {name} client certificate",
        "PayloadContent": p12_data,
        "Password": password,
    }


def build(args):
    base_id = "com.vpnstatus.testtarget." + args.display_name.replace("-", "").replace("_", "").lower()
    payloads = []
    for spec in args.profile:
        name, p12_path, client_id, full_tunnel, routes = spec.split(":", 4)
        cp = cert_payload(base_id, args.display_name, name, p12_path, args.p12_password)
        payloads.append(
            vpn_payload(base_id, name, args.vpn_host, cp["PayloadUUID"],
                        client_id, full_tunnel == "yes", routes)
        )
        payloads.append(cp)

    profile = {
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": base_id,
        "PayloadUUID": _uuid(base_id, "profile"),
        "PayloadDisplayName": args.display_name,
        "PayloadDescription": f"IKEv2 VPN to {args.vpn_host}.",
        "PayloadContent": payloads,
    }

    with open(args.out, "wb") as fh:
        plistlib.dump(profile, fh)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--vpn-host", required=True)
    p.add_argument("--p12-password", required=True)
    p.add_argument("--display-name", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--profile", required=True, action="append",
                   help="name:p12_path:client_id:full_tunnel:routes")
    build(p.parse_args())


if __name__ == "__main__":
    main()
