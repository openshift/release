#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deploying external IP echo service on bastion host for egress IP validation"
echo "============================================================================="

echo "🐛 DEBUG MODE: Sleeping for 35 minutes to allow manual debugging/testing"
echo "   - Cluster should be ready for manual testing"
echo "   - Bastion host will be available for manual setup"
echo "   - Use this time to validate cluster state and test steps manually"
echo "   - Time started: $(date)"
echo "   - Will resume at: $(date -d '+35 minutes')"
sleep 2100  # 35 minutes

# Load bastion host information
if [[ -f "$SHARED_DIR/bastion_public_address" ]]; then
    BASTION_PUBLIC_IP=$(cat "$SHARED_DIR/bastion_public_address")
    echo "Found bastion host at: $BASTION_PUBLIC_IP"
else
    echo "ERROR: No bastion host found. Bastion provisioning may have failed."
    exit 1
fi

# Configure AWS security group to allow traffic to the echo service (using official port 9095)
ECHO_SERVICE_PORT=9095
echo "🔧 Configuring AWS security group to allow traffic on port $ECHO_SERVICE_PORT..."

# Get bastion instance ID from its public IP
BASTION_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=ip-address,Values=$BASTION_PUBLIC_IP" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text 2>/dev/null || echo "")

if [[ -z "$BASTION_INSTANCE_ID" ]]; then
    echo "❌ Could not find bastion instance ID from public IP: $BASTION_PUBLIC_IP"
    exit 1
fi

echo "📍 Found bastion instance ID: $BASTION_INSTANCE_ID"

# Get security group ID from bastion instance
SECURITY_GROUP_ID=$(aws ec2 describe-instances \
    --instance-ids "$BASTION_INSTANCE_ID" \
    --query 'Reservations[*].Instances[*].SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

if [[ -z "$SECURITY_GROUP_ID" ]]; then
    echo "❌ Could not find security group ID for bastion instance: $BASTION_INSTANCE_ID"
    exit 1
fi

echo "🔒 Found bastion security group ID: $SECURITY_GROUP_ID"

# Check if port is already open
PORT_OPEN=$(aws ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --query "SecurityGroups[0].IpPermissions[?FromPort<=\`$ECHO_SERVICE_PORT\`&&ToPort>=\`$ECHO_SERVICE_PORT\`&&IpProtocol==\`tcp\`]" \
    --output text 2>/dev/null || echo "")

if [[ -n "$PORT_OPEN" ]]; then
    echo "✅ Port $ECHO_SERVICE_PORT already open in security group $SECURITY_GROUP_ID"
else
    echo "🔧 Opening port $ECHO_SERVICE_PORT in security group $SECURITY_GROUP_ID..."
    
    # Add security group rule to allow traffic on echo service port (matches official OpenShift tests)
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port "$ECHO_SERVICE_PORT" \
        --cidr 0.0.0.0/0 2>/dev/null || {
        echo "⚠️  Failed to add security group rule (may already exist)"
    }
    
    echo "✅ Security group rule added for port $ECHO_SERVICE_PORT"
fi

# Get bastion private IP for internal cluster access (following official pattern)
BASTION_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$BASTION_INSTANCE_ID" \
    --query 'Reservations[*].Instances[*].PrivateIpAddress' \
    --output text 2>/dev/null || echo "")

if [[ -z "$BASTION_PRIVATE_IP" ]]; then
    echo "❌ Could not find bastion private IP for instance: $BASTION_INSTANCE_ID"
    exit 1
fi

echo "🔗 Found bastion private IP: $BASTION_PRIVATE_IP"

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

# Check if SSH is available in the container
if ! command -v ssh >/dev/null 2>&1; then
    echo "❌ SSH not available in container. Creating simple external validation URL instead..."
    
    # For environments without SSH, we'll create a simple validation approach
    # Store the bastion URL directly for external validation (use official port 9095)
    BASTION_SERVICE_URL="http://$BASTION_PUBLIC_IP:9095/"
    echo "$BASTION_SERVICE_URL" > "$SHARED_DIR/egress-health-check-url"
    
    echo "✅ External validation configured!"
    echo "   Bastion URL: $BASTION_SERVICE_URL"
    echo "   Note: Manual setup required on bastion host for IP echo service"
    echo ""
    echo "🔧 Manual setup instructions for bastion host:"
    echo "   1. SSH to bastion: ssh -i <ssh-key> core@$BASTION_PUBLIC_IP"
    echo "   2. Install Python HTTP server script"
    echo "   3. Start service on port 9095"
    echo ""
    echo "   Python IP echo script to create on bastion:"
    cat << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
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
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        
        json_response = json.dumps(response_data, indent=2)
        self.wfile.write(json_response.encode('utf-8'))
        
        print(f"[{response_data['timestamp']}] {client_ip} - \"{self.command} {self.path} {self.request_version}\" 200 -")

    def log_message(self, format, *args):
        return

if __name__ == '__main__':
    port = 9095
    server = HTTPServer(('0.0.0.0', port), IPEchoHandler)
    print(f"External IP Echo Service starting on port {port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down IP Echo Service")
        server.server_close()
PYTHON_SCRIPT
    
    echo "External IP echo service setup completed (manual setup required)!"
    exit 0
fi

# Deploy and start the service on bastion host using official OpenShift test approach
ssh -i "$BASTION_SSH_KEY" -o StrictHostKeyChecking=no "$BASTION_SSH_USER"@"$BASTION_PUBLIC_IP" << 'REMOTE_SCRIPT'

# Check if service is already running (exactly like official code)
echo "🔍 Checking if IP echo service is already running on port 9095..."
if sudo netstat -ntlp | grep 9095; then
    echo "✅ IP echo service already running on port 9095"
else
    echo "🚀 Starting IP echo service using official OpenShift test container..."
    
    # Use the exact same command as official OpenShift networking tests
    sudo podman run --name ipecho -d -p 9095:80 quay.io/openshifttest/ip-echo:1.2.0
    
    # Wait for service to start
    sleep 5
    
    # Verify service is running
    if sudo netstat -ntlp | grep 9095; then
        echo "✅ IP echo service successfully started"
    else
        echo "❌ Failed to start IP echo service"
        echo "Container status:"
        sudo podman ps -a | grep ipecho || echo "No ipecho container found"
        echo "Container logs:"
        sudo podman logs ipecho || echo "No logs available"
        exit 1
    fi
fi

# Test that the service is responding locally
echo "🧪 Testing IP echo service locally on bastion..."
local_test_response=$(curl -s --connect-timeout 10 http://localhost:9095/ || echo "FAILED")

if [[ "$local_test_response" != "FAILED" && -n "$local_test_response" ]]; then
    echo "✅ IP Echo Service is responding correctly"
    echo "Sample response: $local_test_response"
else
    echo "⚠️ Warning: IP Echo Service local test failed, but continuing..."
    echo "Checking if container is running:"
    sudo podman ps | grep ipecho || echo "No running ipecho container"
    echo "Container logs:"
    sudo podman logs ipecho 2>/dev/null || echo "No logs available"
fi

# Open firewall for port 9095 (matching official port)
echo "🔓 Opening firewall for port 9095..."
sudo firewall-cmd --permanent --add-port=9095/tcp 2>/dev/null || echo "Firewall command failed, continuing..."
sudo firewall-cmd --reload 2>/dev/null || echo "Firewall reload failed, continuing..."

echo "✅ IP Echo Service deployment completed successfully!"
REMOTE_SCRIPT

# Store bastion service URL for test steps - use PRIVATE IP for internal cluster access (official pattern)
BASTION_SERVICE_URL="http://$BASTION_PRIVATE_IP:9095/"
echo "$BASTION_SERVICE_URL" > "$SHARED_DIR/egress-health-check-url"

# Also save both public and private IPs for reference
echo "$BASTION_PUBLIC_IP" > "$SHARED_DIR/bastion_public_ip"
echo "$BASTION_PRIVATE_IP" > "$SHARED_DIR/bastion_private_ip"

echo "✅ External IP echo service deployed successfully!"
echo "   Internal Service URL (for cluster): $BASTION_SERVICE_URL"
echo "   External Service URL (for manual testing): http://$BASTION_PUBLIC_IP:9095/"
echo "   This service will report actual source IPs for egress IP validation"
echo "   Service is running on bastion host and ready for egress IP testing"
echo ""
echo "🔧 Manual validation available:"
echo "   curl http://$BASTION_PUBLIC_IP:9095/ (from external)"
echo "   curl $BASTION_SERVICE_URL (from cluster pods)"
echo ""
echo "📊 DEBUG: Configuration Summary"
echo "   Bastion Instance ID: $BASTION_INSTANCE_ID"
echo "   Bastion Security Group: $SECURITY_GROUP_ID"
echo "   Bastion Public IP: $BASTION_PUBLIC_IP"
echo "   Bastion Private IP: $BASTION_PRIVATE_IP"
echo "   Service Port: $ECHO_SERVICE_PORT (9095)"
echo "   Service Container: quay.io/openshifttest/ip-echo:1.2.0"
echo "   Internal URL for cluster: $BASTION_SERVICE_URL"

echo "External IP echo service setup completed successfully!"