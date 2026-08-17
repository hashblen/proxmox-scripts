#!/usr/bin/env bash
# Sets up a Tailscale exit node that forwards traffic through a WireGuard VPN
#
# Prerequisites on Proxmox HOST:
#   echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> /etc/pve/lxc/<CTID>.conf
#   echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> /etc/pve/lxc/<CTID>.conf
#   pct reboot <CTID>
#
# Requires:
#   - Tailscale installed and authenticated
#   - WireGuard config placed at /etc/wireguard/<name>.conf
#
# Usage:
#   ./setup.sh mullvad

set -euo pipefail

VPN_NAME="${1:-mullvad}"
WG_DIR="/etc/wireguard"
WG_FILE="${WG_DIR}/${VPN_NAME}.conf"
ROUTE_TABLE=39

if ! command -v tailscale >/dev/null; then
    echo "Tailscale is not installed."
    exit 1
fi

if ! command -v wg >/dev/null; then
    apt update
    apt install -y wireguard-tools nftables
fi

mkdir -p "$WG_DIR"
mkdir -p /usr/local/bin

if [ ! -f "$WG_FILE" ]; then
    echo "Missing WireGuard config:"
    echo "  $WG_FILE"
    echo
    echo "Place your WireGuard provider config there and rerun."
    exit 1
fi


cat > /usr/local/bin/post-up.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WG_IFACE="$1"
ROUTE_TABLE=39

if [ -z "$WG_IFACE" ]; then
    echo "Usage: $0 <wg_interface>"
    exit 1
fi

echo "[+] Installing nftables rules"

nft delete table inet ts-vpn 2>/dev/null || true

nft -f - <<EOF_NFT
table inet ts-vpn {

    chain prerouting {
        type filter hook prerouting priority mangle;
        policy accept;

        iifname "tailscale0" \
        meta mark set (meta mark & 0xff00ffff) | 0x00040000
    }

    chain input {
        type filter hook input priority filter;
        policy accept;

        iifname "tailscale0" accept

        iifname != "tailscale0" \
        ip saddr 100.64.0.0/10 drop
    }

    chain forward {
        type filter hook forward priority filter;
        policy accept;
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;

        meta mark & 0x00ff0000 == 0x00040000 masquerade
    }
}
EOF_NFT


echo "[+] Adding policy routing"

ip route add default dev "$WG_IFACE" table "$ROUTE_TABLE" 2>/dev/null || true
ip -6 route add default dev "$WG_IFACE" table "$ROUTE_TABLE" 2>/dev/null || true

ip rule add fwmark 0x40000/0xff0000 lookup "$ROUTE_TABLE" 2>/dev/null || true
ip -6 rule add fwmark 0x40000/0xff0000 lookup "$ROUTE_TABLE" 2>/dev/null || true
EOF


cat > /usr/local/bin/pre-down.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROUTE_TABLE=39

echo "[-] Removing nftables rules"

nft delete table inet ts-vpn 2>/dev/null || true

echo "[-] Removing routing rules"

ip rule del fwmark 0x40000/0xff0000 lookup "$ROUTE_TABLE" 2>/dev/null || true
ip -6 rule del fwmark 0x40000/0xff0000 lookup "$ROUTE_TABLE" 2>/dev/null || true

ip route flush table "$ROUTE_TABLE" 2>/dev/null || true
ip -6 route flush table "$ROUTE_TABLE" 2>/dev/null || true
EOF


chmod +x /usr/local/bin/post-up.sh
chmod +x /usr/local/bin/pre-down.sh


echo "[+] Patching WireGuard config"

sed -i '/^Table = off$/d' "$WG_FILE"
sed -i '/^PostUp =/d' "$WG_FILE"
sed -i '/^PreDown =/d' "$WG_FILE"

sed -i '/^\[Interface\]/a\
Table = off\n\
PostUp = /usr/local/bin/post-up.sh %i\n\
PreDown = /usr/local/bin/pre-down.sh %i' "$WG_FILE"

chmod 600 "$WG_FILE"


echo "[+] Enabling IP forwarding"

cat >/etc/sysctl.d/99-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

sysctl -p /etc/sysctl.d/99-tailscale.conf


echo "[+] Configuring Tailscale"

tailscale set --advertise-exit-node
tailscale set --netfilter-mode=nodivert


echo "[+] Configuring systemd ordering"

mkdir -p "/etc/systemd/system/wg-quick@${VPN_NAME}.service.d"

cat > "/etc/systemd/system/wg-quick@${VPN_NAME}.service.d/override.conf" <<EOF
[Unit]
After=tailscaled.service network-online.target
Wants=network-online.target
EOF

systemctl daemon-reload


if grep -qE '^[[:space:]]*DNS[[:space:]]*=' "$WG_FILE"; then
    if ! command -v resolvconf >/dev/null; then
        echo "[+] WireGuard DNS configured; installing resolvconf provider"
        apt update
        apt install -y openresolv
    fi
fi

echo "[+] Starting WireGuard"

if ! wg show "$VPN_NAME" >/dev/null 2>&1; then
    wg-quick up "$VPN_NAME"
fi

systemctl enable "wg-quick@${VPN_NAME}"


echo
echo "=== Verification ==="

wg show
nft list table inet ts-vpn
ip route show table "$ROUTE_TABLE"
ip rule list
tailscale status

echo
echo "Done."
echo "Test from a tailnet client using this exit node:"
echo "  curl https://am.i.mullvad.net/json"
