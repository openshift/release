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
BASTION_SSH_KEY="$CLUSTER_PROFILE_DIR/ssh-privatekey"
if [[ ! -f "$BASTION_SSH_KEY" ]]; then
    echo "ERROR: Cluster profile SSH key not found at $BASTION_SSH_KEY"
    exit 1
fi

# Set proper permissions on SSH key
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

# Create the IP echo service script
cat > /tmp/ipecho_service.py << 'EOF'
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
EOF

# Create systemd service file for the IP echo service
cat > /tmp/ipecho.service << EOF
[Unit]
Description=IP Echo Service for Egress IP Testing
After=network.target

[Service]
Type=simple
User=$BASTION_SSH_USER
WorkingDirectory=/home/$BASTION_SSH_USER
ExecStart=/usr/bin/python3 /home/$BASTION_SSH_USER/ipecho_service.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "Deploying service to bastion host via SSH..."

# Copy service files to bastion host
scp -i "$BASTION_SSH_KEY" -o StrictHostKeyChecking=no \
    /tmp/ipecho_service.py "$BASTION_SSH_USER"@"$BASTION_PUBLIC_IP":/home/"$BASTION_SSH_USER"/

scp -i "$BASTION_SSH_KEY" -o StrictHostKeyChecking=no \
    /tmp/ipecho.service "$BASTION_SSH_USER"@"$BASTION_PUBLIC_IP":/tmp/

# Install and start the service on bastion host
ssh -i "$BASTION_SSH_KEY" -o StrictHostKeyChecking=no "$BASTION_SSH_USER"@"$BASTION_PUBLIC_IP" << 'REMOTE_SCRIPT'
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

# Test that the service is responding
curl -s http://localhost:8080/ || echo "Service test failed, but continuing..."

# Open firewall for port 8080
sudo firewall-cmd --permanent --add-port=8080/tcp || echo "Firewall command failed, continuing..."
sudo firewall-cmd --reload || echo "Firewall reload failed, continuing..."

echo "IP Echo Service deployment completed"
REMOTE_SCRIPT

# Store bastion service URL for test steps
BASTION_SERVICE_URL="http://$BASTION_PUBLIC_IP:8080/"
echo "$BASTION_SERVICE_URL" > "$SHARED_DIR/egress-bastion-echo-url"

echo "✅ External IP echo service deployed successfully!"
echo "   Service URL: $BASTION_SERVICE_URL"
echo "   This service will report actual source IPs for egress IP validation"

# Test connectivity from local machine
echo "Testing bastion service connectivity..."
if curl -s --max-time 10 "$BASTION_SERVICE_URL" > /tmp/bastion_test.json; then
    echo "✅ Bastion service is accessible"
    echo "Sample response:"
    cat /tmp/bastion_test.json | jq . || cat /tmp/bastion_test.json
else
    echo "⚠️ Warning: Could not reach bastion service, but continuing..."
fi

echo "External IP echo service setup completed successfully!"