#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure our UID is in /etc/passwd for SSH
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

echo "Setting up API tunnel to ARO private cluster via bastion..."

# Authenticate with Azure
echo "Authenticating with Azure..."
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

# API tunnel port - use 16443 (will be opened in NSG)
API_TUNNEL_PORT=16443

# Get bastion connection details
ssh_key_file_name="ssh-privatekey"
ssh_key=${CLUSTER_PROFILE_DIR}/${ssh_key_file_name}
bastion_dns=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
bastion_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")

echo "Bastion: ${bastion_user}@${bastion_dns}"

# Get the ARO API server address from kubeconfig (could be hostname or IP)
api_server=$(grep -oP 'server: https://\K[^:]+' "${SHARED_DIR}/kubeconfig" | head -n 1)
api_port=$(grep -oP 'server: https://[^:]+:\K[0-9]+' "${SHARED_DIR}/kubeconfig" | head -n 1 || echo "6443")
echo "ARO API server from kubeconfig: ${api_server}:${api_port}"

# Resolve API server hostname to IP on bastion (bastion has VNet DNS access)
echo "Resolving API server hostname on bastion..."
api_ip=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${ssh_key}" \
    ${bastion_user}@${bastion_dns} "getent hosts ${api_server} | awk '{print \$1}' | head -n 1")

if [[ -z "${api_ip}" ]]; then
    echo "ERROR: Could not resolve ${api_server} on bastion"
    exit 1
fi

echo "Resolved ${api_server} -> ${api_ip}"

# Test connectivity from bastion to ARO API
echo "Testing ARO API connectivity from bastion..."
if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${ssh_key}" \
    ${bastion_user}@${bastion_dns} "curl -k -s -m 5 https://${api_ip}:${api_port}/api >/dev/null 2>&1"; then
    echo "WARNING: Could not reach ARO API from bastion, but continuing..."
fi

# Set up socat tunnel ON THE BASTION that forwards bastion:6443 -> ARO API
# This persists across CI steps (unlike tunnel from CI pod which dies with the container)
echo "Setting up persistent API tunnel on bastion (bastion:6443 -> ${api_ip}:${api_port})..."

cat > /tmp/setup-tunnel.sh <<EOF
#!/bin/bash
set -x

# Use port passed from parent script
SOCAT_PORT=${API_TUNNEL_PORT}

# Kill any existing tunnel
pkill -f "socat.*\${SOCAT_PORT}" || true
sleep 2

# Install socat if not present
if ! command -v socat &>/dev/null; then
    echo "Installing socat..."
    sudo yum install -y socat || sudo dnf install -y socat || true
fi

# Generate self-signed certificate for HTTPS listener
if [[ ! -f /tmp/tunnel.pem ]]; then
    echo "Generating self-signed certificate..."
    openssl req -x509 -newkey rsa:2048 -keyout /tmp/tunnel.key -out /tmp/tunnel.crt \
        -days 365 -nodes -subj "/CN=bastion" 2>/dev/null
    cat /tmp/tunnel.crt /tmp/tunnel.key > /tmp/tunnel.pem
fi

# Start socat with SSL on both ends: HTTPS listener -> HTTPS to ARO API
# OPENSSL-LISTEN: Accept HTTPS connections from clients
# OPENSSL: Connect to ARO API with HTTPS
nohup socat -d -d OPENSSL-LISTEN:\${SOCAT_PORT},cert=/tmp/tunnel.pem,verify=0,fork,reuseaddr \
    OPENSSL:${api_ip}:${api_port},verify=0 > /tmp/api-tunnel.log 2>&1 &

# Save PID
echo \$! > /tmp/api-tunnel.pid
SOCAT_PID=\$!

echo "Started socat on port \${SOCAT_PORT} (PID: \${SOCAT_PID})"
sleep 3

# Check if socat is still running
if ! ps -p \${SOCAT_PID} >/dev/null 2>&1; then
    echo "ERROR: socat process died immediately"
    cat /tmp/api-tunnel.log
    exit 1
fi

# Check if port is listening
if ! ss -tlnp 2>/dev/null | grep -q ":\${SOCAT_PORT}" && ! netstat -tlnp 2>/dev/null | grep -q ":\${SOCAT_PORT}"; then
    echo "ERROR: Port \${SOCAT_PORT} is not listening"
    cat /tmp/api-tunnel.log
    exit 1
fi

# Test socat
echo "Testing socat on port \${SOCAT_PORT}..."
if curl -k -s -m 5 https://localhost:\${SOCAT_PORT}/api >/dev/null 2>&1; then
    echo "Tunnel is ready on bastion (port \${SOCAT_PORT} -> ARO API)"
    exit 0
else
    echo "ERROR: socat not responding"
    cat /tmp/api-tunnel.log
    exit 1
fi
EOF

scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${ssh_key}" \
    /tmp/setup-tunnel.sh ${bastion_user}@${bastion_dns}:/tmp/setup-tunnel.sh

# Open API tunnel port in bastion NSG
echo "Opening port ${API_TUNNEL_PORT} in bastion NSG..."
RESOURCE_GROUP=$(cat "${SHARED_DIR}/resourcegroup")
BASTION_NSG=$(az network nsg list --resource-group "${RESOURCE_GROUP}" --query "[?contains(name, 'bastion')].name" -o tsv | head -n 1)

if [[ -n "${BASTION_NSG}" ]]; then
    echo "Found bastion NSG: ${BASTION_NSG}"
    # Check if rule exists, if not create it
    if ! az network nsg rule show --resource-group "${RESOURCE_GROUP}" --nsg-name "${BASTION_NSG}" --name "allow-api-tunnel" &>/dev/null; then
        echo "Creating NSG rule to allow port ${API_TUNNEL_PORT}..."
        az network nsg rule create \
            --resource-group "${RESOURCE_GROUP}" \
            --nsg-name "${BASTION_NSG}" \
            --name "allow-api-tunnel" \
            --priority 500 \
            --source-address-prefixes '*' \
            --destination-port-ranges ${API_TUNNEL_PORT} \
            --access Allow \
            --protocol Tcp \
            --description "Allow API tunnel access from CI pods"
    else
        echo "NSG rule allow-api-tunnel already exists"
    fi
else
    echo "ERROR: Could not find bastion NSG"
    exit 1
fi

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${ssh_key}" \
    ${bastion_user}@${bastion_dns} "chmod +x /tmp/setup-tunnel.sh && /tmp/setup-tunnel.sh"

# Optionally block outbound internet access for air-gapped testing
if [[ "${BLOCK_OUTBOUND_INTERNET:-false}" == "true" ]]; then
    echo "Blocking outbound internet access (air-gapped mode)..."

    # Get worker NSG
    WORKER_NSG=$(az network nsg list --resource-group "${RESOURCE_GROUP}" --query "[?contains(name, 'worker') || contains(name, 'node')].name" -o tsv | head -n 1)

    if [[ -n "${WORKER_NSG}" ]]; then
        echo "Found worker NSG: ${WORKER_NSG}"

        # Add deny rule for outbound internet (priority 4096 = last rule before default allow)
        if ! az network nsg rule show --resource-group "${RESOURCE_GROUP}" --nsg-name "${WORKER_NSG}" --name "deny-outbound-internet" &>/dev/null; then
            echo "Creating NSG rule to block outbound internet from workers..."
            az network nsg rule create \
                --resource-group "${RESOURCE_GROUP}" \
                --nsg-name "${WORKER_NSG}" \
                --name "deny-outbound-internet" \
                --priority 4096 \
                --direction Outbound \
                --access Deny \
                --protocol '*' \
                --source-address-prefixes '*' \
                --destination-address-prefixes Internet \
                --destination-port-ranges '*' \
                --description "Block all outbound internet access for air-gapped testing"
            echo "✓ Worker outbound internet access blocked"
        else
            echo "Worker outbound block rule already exists"
        fi
    else
        echo "WARNING: Could not find worker NSG to block outbound traffic"
    fi

    # Also block bastion's outbound to prevent proxy bypass
    BASTION_NSG=$(az network nsg list --resource-group "${RESOURCE_GROUP}" --query "[?contains(name, 'bastion')].name" -o tsv | head -n 1)

    if [[ -n "${BASTION_NSG}" ]]; then
        echo "Found bastion NSG: ${BASTION_NSG}"

        # Add deny rule for bastion outbound (except SSH which is needed for CI)
        if ! az network nsg rule show --resource-group "${RESOURCE_GROUP}" --nsg-name "${BASTION_NSG}" --name "deny-bastion-outbound-internet" &>/dev/null; then
            echo "Creating NSG rule to block outbound internet from bastion (preserving SSH)..."
            # Block all ports except 22 (SSH - needed for CI pod access)
            az network nsg rule create \
                --resource-group "${RESOURCE_GROUP}" \
                --nsg-name "${BASTION_NSG}" \
                --name "deny-bastion-outbound-internet" \
                --priority 4095 \
                --direction Outbound \
                --access Deny \
                --protocol Tcp \
                --source-address-prefixes '*' \
                --destination-address-prefixes Internet \
                --destination-port-ranges 80 443 3128 \
                --description "Block HTTP/HTTPS/Proxy outbound from bastion for air-gapped testing"
            echo "✓ Bastion proxy outbound blocked (SSH preserved for CI access)"
        else
            echo "Bastion outbound block rule already exists"
        fi
    else
        echo "WARNING: Could not find bastion NSG"
    fi

    # Verify outbound is blocked from bastion
    echo "Verifying air-gapped configuration..."
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${ssh_key}" \
        ${bastion_user}@${bastion_dns} "timeout 5 curl -s https://www.google.com >/dev/null 2>&1"; then
        echo "WARNING: Outbound internet is still accessible from bastion"
    else
        echo "✓ Air-gapped mode verified: outbound internet blocked"
    fi
fi

# Update kubeconfig to use bastion public IP on API tunnel port
echo "Updating kubeconfig to use bastion as proxy (${bastion_dns}:${API_TUNNEL_PORT})..."
sed -i "s|server: https://${api_server}:${api_port}|server: https://${bastion_dns}:${API_TUNNEL_PORT}|g" "${SHARED_DIR}/kubeconfig"

# Verify API access through bastion tunnel
echo "Verifying API access through bastion tunnel..."
if oc --kubeconfig="${SHARED_DIR}/kubeconfig" get nodes >/dev/null 2>&1; then
    echo "✓ API tunnel is working - cluster is accessible via ${bastion_dns}:${API_TUNNEL_PORT}"
else
    echo "ERROR: Cannot access cluster through bastion tunnel"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${ssh_key}" \
        ${bastion_user}@${bastion_dns} "cat /tmp/api-tunnel.log || true"
    exit 1
fi

echo "API tunnel setup complete. All subsequent steps can access the cluster via bastion."
