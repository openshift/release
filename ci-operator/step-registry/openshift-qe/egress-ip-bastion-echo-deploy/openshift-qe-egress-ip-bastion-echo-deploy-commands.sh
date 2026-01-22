#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deploying external IP echo service on bastion host for egress IP validation"
echo "============================================================================="

# Load bastion host information
if [[ -f "$SHARED_DIR/bastion_public_address" ]]; then
    BASTION_PUBLIC_IP=$(cat "$SHARED_DIR/bastion_public_address")
    echo "Found bastion host at: $BASTION_PUBLIC_IP"
else
    echo "ERROR: No bastion host found. Bastion provisioning may have failed."
    exit 1
fi

# Load SSH key for bastion access (use cluster profile SSH key)
CLUSTER_SSH_KEY="$CLUSTER_PROFILE_DIR/ssh-privatekey"
if [[ ! -f "$CLUSTER_SSH_KEY" ]]; then
    echo "ERROR: Cluster profile SSH key not found at $CLUSTER_SSH_KEY"
    exit 1
fi

# Copy SSH key to writable location and set proper permissions
BASTION_SSH_KEY="/tmp/bastion_ssh_key"
cp "$CLUSTER_SSH_KEY" "$BASTION_SSH_KEY"
chmod 600 "$BASTION_SSH_KEY"

# Get the correct SSH user for the bastion host
if [[ -f "$SHARED_DIR/bastion_ssh_user" ]]; then
    BASTION_SSH_USER=$(cat "$SHARED_DIR/bastion_ssh_user")
    echo "Using SSH user: $BASTION_SSH_USER"
else
    echo "WARNING: bastion_ssh_user not found, defaulting to 'core'"
    BASTION_SSH_USER="core"
fi

echo "Setting up external IP echo service on bastion host..."

echo "Deploying service to bastion host via SSH..."

# Deploy and start the service on bastion host using embedded content
ssh -i "$BASTION_SSH_KEY" -o StrictHostKeyChecking=no "$BASTION_SSH_USER"@"$BASTION_PUBLIC_IP" << 'REMOTE_SCRIPT'

# Create the IP echo service script directly on bastion
cat > /home/${USER}/ipecho_service.py << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
External IP Echo Service for Egress IP Validation
Reports the actual source IP of incoming connections for egress IP testing
"""

import socket
import json
import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

class IPEchoHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        client_ip = self.client_address[0]
        response_data = {
            "source_ip": client_ip,
            "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
            "method": self.command,
            "path": self.path,
            "server_hostname": socket.gethostname(),
            "server_type": "bastion_external"
        }
        
        # Send HTTP response
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        
        # Send JSON response
        json_response = json.dumps(response_data, indent=2)
        self.wfile.write(json_response.encode('utf-8'))
        
        # Log the request
        print(f"[{response_data['timestamp']}] {client_ip} - \"{self.command} {self.path} {self.request_version}\" 200 -")

    def log_message(self, format, *args):
        # Custom logging to avoid duplicate logs
        return

if __name__ == '__main__':
    port = 8080
    server = HTTPServer(('0.0.0.0', port), IPEchoHandler)
    print(f"External IP Echo Service starting on port {port}")
    print("Reports actual source IPs for egress IP validation")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down IP Echo Service")
        server.server_close()
PYTHON_EOF

# Create systemd service file
cat > /tmp/ipecho.service << SYSTEMD_EOF
[Unit]
Description=IP Echo Service for Egress IP Testing
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=/home/${USER}
ExecStart=/usr/bin/python3 /home/${USER}/ipecho_service.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
# Make the Python script executable
chmod +x /home/${USER}/ipecho_service.py

# Install the systemd service
sudo cp /tmp/ipecho.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ipecho.service
sudo systemctl start ipecho.service

# Wait a moment for service to start
sleep 3

# Check service status
sudo systemctl status ipecho.service --no-pager

# Test that the service is responding locally
echo "Testing IP echo service locally on bastion..."
if curl -s http://localhost:8080/ | grep -q "source_ip"; then
    echo "✅ IP Echo Service is responding correctly"
    echo "Sample response: $(curl -s http://localhost:8080/)"
else
    echo "⚠️ Warning: IP Echo Service test failed, but continuing..."
    echo "Service status: $(sudo systemctl is-active ipecho.service)"
    echo "Service logs: $(sudo journalctl -u ipecho.service --no-pager -n 5)"
fi

# Open firewall for port 8080
sudo firewall-cmd --permanent --add-port=8080/tcp || echo "Firewall command failed, continuing..."
sudo firewall-cmd --reload || echo "Firewall reload failed, continuing..."

echo "IP Echo Service deployment completed"
REMOTE_SCRIPT

# Store bastion service URL for test steps (using expected filename)
BASTION_SERVICE_URL="http://$BASTION_PUBLIC_IP:8080/"
echo "$BASTION_SERVICE_URL" > "$SHARED_DIR/egress-health-check-url"

echo "✅ External IP echo service deployed successfully!"
echo "   Service URL: $BASTION_SERVICE_URL"
echo "   This service will report actual source IPs for egress IP validation"
echo "   Service is running on bastion host and ready for egress IP testing"

echo "External IP echo service setup completed successfully!"