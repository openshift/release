#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Provisioning ipecho server on dev-scripts host"

source "${SHARED_DIR}/packet-conf.sh"

IPECHO_HOST_IP="192.168.111.1"
IPECHO_PORT="${IPECHO_PORT:-9095}"

# Deploy ipecho server on the provisioning host via SSH
# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${IPECHO_PORT}" << 'EOF'
set -euxo pipefail

IPECHO_PORT="$1"

# Write the ipecho Python HTTP server
cat > /usr/local/bin/ipecho.py << 'PYEOF'
#!/usr/bin/env python3
"""Minimal HTTP server that returns the client source IP address."""
import http.server
import socketserver
import sys

class IPEchoHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        client_ip = self.client_address[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(client_ip.encode("utf-8"))
        self.wfile.write(b"\n")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" %
                         (self.client_address[0],
                          self.log_date_time_string(),
                          fmt % args))

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9095
    with socketserver.TCPServer(("0.0.0.0", port), IPEchoHandler) as httpd:
        print(f"ipecho server listening on 0.0.0.0:{port}")
        httpd.serve_forever()
PYEOF
chmod +x /usr/local/bin/ipecho.py

# Create systemd unit
cat > /etc/systemd/system/ipecho.service << SVCEOF
[Unit]
Description=ipecho HTTP server for EgressIP testing
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ipecho.py ${IPECHO_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now ipecho.service

# Verify the service is running
for i in $(seq 1 30); do
    if curl -sf "http://192.168.111.1:${IPECHO_PORT}" >/dev/null 2>&1; then
        echo "ipecho server is ready on port ${IPECHO_PORT}"
        curl -s "http://192.168.111.1:${IPECHO_PORT}"
        exit 0
    fi
    echo "Waiting for ipecho server... attempt ${i}/30"
    sleep 2
done

echo "ERROR: ipecho server did not become ready"
systemctl status ipecho.service || true
journalctl -u ipecho.service --no-pager -n 20 || true
exit 1
EOF

echo "ipecho server deployed successfully"

# Write outputs for downstream test steps
echo "${IPECHO_HOST_IP}" > "${SHARED_DIR}/ipecho_host_ip"
echo "http://${IPECHO_HOST_IP}:${IPECHO_PORT}" > "${SHARED_DIR}/ipecho_url"

echo "ipecho_host_ip: ${IPECHO_HOST_IP}"
echo "ipecho_url: http://${IPECHO_HOST_IP}:${IPECHO_PORT}"
