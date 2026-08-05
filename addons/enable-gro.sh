#!/usr/bin/env bash
set -euo pipefail

# Install ethtool
apt-get update -qq
apt-get install -y ethtool

# Determine the primary network interface
NETDEV=$(ip -o route get 8.8.8.8 | cut -f 5 -d " ")

if [[ -z "$NETDEV" ]]; then
    echo "Failed to determine network interface."
    exit 1
fi

# Create the systemd service
cat > /etc/systemd/system/udpgroforwarding.service <<EOF
[Unit]
Description=UDPGroForwarding
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -K ${NETDEV} rx-udp-gro-forwarding on rx-gro-list off

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable, and start the service
systemctl daemon-reload
systemctl enable --now udpgroforwarding.service

echo "udpgroforwarding.service has been installed, enabled, and started."
