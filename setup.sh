#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURE THESE BEFORE RUNNING
# ============================================================
BACKEND_IP="192.168.1.50"    # IP/hostname of what you're proxying to (Jellyfin directly, or e.g. an OPNsense frontend)
BACKEND_PORT="8096"          # e.g. 8096 for Jellyfin directly, 443 for an HTTPS frontend like OPNsense
BACKEND_SCHEME="http"        # "http" or "https" — use "https" for things like an OPNsense web frontend
FOREIGN_IFACE=""             # e.g. "eth0" or "wlan0" — the interface on the foreign network.
                              # Leave blank to have nginx listen on all interfaces instead of just this one.
AUTH_KEY=""                   # Tailscale auth key
# ============================================================

echo "== Step 1: Update system =="
sudo apt update && sudo apt upgrade -y

echo "== Step 2: Install nginx =="
sudo apt install -y nginx

echo "== Step 3: Configure reverse proxy =="
sudo rm -f /etc/nginx/sites-enabled/default

LISTEN_DIRECTIVE="listen 80;"
if [ -n "${FOREIGN_IFACE}" ]; then
    FOREIGN_IP=$(ip -4 addr show "${FOREIGN_IFACE}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
    if [ -n "${FOREIGN_IP}" ]; then
        LISTEN_DIRECTIVE="listen ${FOREIGN_IP}:80;"
        echo "Binding nginx to ${FOREIGN_IP} on interface ${FOREIGN_IFACE}"
    else
        echo "WARNING: could not determine an IP for ${FOREIGN_IFACE}."
        echo "Make sure the Pi is already connected to the foreign network (Wi-Fi join isn't automated by this script)."
        echo "Falling back to listening on all interfaces for now."
    fi
fi

SSL_VERIFY_LINE=""
if [ "${BACKEND_SCHEME}" = "https" ]; then
    # Backend cert (e.g. OPNsense's self-signed/LAN cert) won't validate against nginx's
    # default trust store — this is fine to disable since traffic is already inside Tailscale/LAN.
    SSL_VERIFY_LINE="        proxy_ssl_verify off;"
fi

sudo tee /etc/nginx/sites-available/jellyfin > /dev/null <<EOF
server {
    ${LISTEN_DIRECTIVE}
    server_name _;

    location / {
        proxy_pass ${BACKEND_SCHEME}://${BACKEND_IP}:${BACKEND_PORT};
${SSL_VERIFY_LINE}
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Jellyfin uses websockets for live updates/sync
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Avoid buffering issues with large media responses
        proxy_buffering off;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/jellyfin /etc/nginx/sites-enabled/jellyfin
sudo nginx -t
sudo systemctl restart nginx

echo "== Step 4: Install Tailscale =="
curl -fsSL https://tailscale.com/install.sh | sh

echo "== Step 5: Bring up Tailscale =="
echo "A login URL will be printed below — open it in a browser to authenticate this Pi to your tailnet."
sudo tailscale up --accept-routes --advertise-tags=tag:jellyfin-proxy --authkey=$AUTH_KEY

echo "== Step 6: Verify the backend is reachable over Tailscale/LAN =="
if curl -sfk -o /dev/null "${BACKEND_SCHEME}://${BACKEND_IP}:${BACKEND_PORT}"; then
    echo "OK: backend reachable at ${BACKEND_SCHEME}://${BACKEND_IP}:${BACKEND_PORT}"
else
    echo "WARNING: could not reach ${BACKEND_SCHEME}://${BACKEND_IP}:${BACKEND_PORT}."
    echo "Double check BACKEND_IP/BACKEND_PORT/BACKEND_SCHEME at the top of this script, and that Tailscale is connected."
fi

echo ""
echo "== Done =="
echo "Current IPs on this Pi:"
ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}(?=.*scope global)' || true
echo ""
echo "Point the TV's (or browser's) Jellyfin/frontend connection at: http://<the-Pi's-IP-on-the-foreign-network>"
echo "(plain http, even though the backend may be https — the Pi terminates that internally)"
echo ""
echo "NOT automated by this script (do these manually if needed):"
echo "  - Joining the Pi to the foreign Wi-Fi network (use raspi-config or nmcli/nmtui first)"
echo "  - The Tailscale login URL above requires opening it in a browser once"