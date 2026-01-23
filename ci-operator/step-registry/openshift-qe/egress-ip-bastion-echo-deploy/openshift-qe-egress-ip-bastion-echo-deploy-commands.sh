#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deploying external IP echo service on bastion host for egress IP validation"
echo "============================================================================="

# Script now runs automatically without debug sleep

# Load bastion host information
if [[ -f "$SHARED_DIR/bastion_public_address" ]]; then
    BASTION_PUBLIC_IP=$(cat "$SHARED_DIR/bastion_public_address")
    echo "Found bastion host at: $BASTION_PUBLIC_IP"
else
    echo "ERROR: No bastion host found. Bastion provisioning may have failed."
    exit 1
fi

# Get bastion private IP for internal cluster access
if [[ -f "$SHARED_DIR/bastion_private_address" ]]; then
    BASTION_PRIVATE_IP=$(cat "$SHARED_DIR/bastion_private_address")
    echo "Found bastion private IP: $BASTION_PRIVATE_IP"
else
    echo "WARNING: No bastion private IP found, using public IP as fallback"
    BASTION_PRIVATE_IP="$BASTION_PUBLIC_IP"
fi

# Get the correct SSH user for the bastion host
if [[ -f "$SHARED_DIR/bastion_ssh_user" ]]; then
    BASTION_SSH_USER=$(cat "$SHARED_DIR/bastion_ssh_user")
    echo "Using SSH user: $BASTION_SSH_USER"
else
    echo "WARNING: bastion_ssh_user not found, defaulting to 'core'"
    BASTION_SSH_USER="core"
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

echo "Setting up external IP echo service on bastion host..."

# Use the exact proven command from official OpenShift networking tests
IPECHO_COMMAND="sudo netstat -ntlp | grep 9095 || sudo podman run --name ipecho -d -p 9095:80 quay.io/openshifttest/ip-echo:1.2.0"
echo "Running command: $IPECHO_COMMAND"

# Deploy the service exactly like the official code
ssh -i "$BASTION_SSH_KEY" -o StrictHostKeyChecking=no "$BASTION_SSH_USER"@"$BASTION_PUBLIC_IP" "$IPECHO_COMMAND"

echo "✅ IP echo service deployed successfully!"

# Update AWS security group to allow port 9095 (simplified approach)
echo "🔧 Configuring AWS security group to allow port 9095..."

# Get infrastructure name from cluster
INFRA_ID=$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)
echo "Infrastructure ID: $INFRA_ID"

# Try to update security group rules for port 9095
aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=${INFRA_ID}-bastion-sg" \
    --query 'SecurityGroups[0].GroupId' \
    --output text > /tmp/sg_id.txt 2>/dev/null || echo "unknown" > /tmp/sg_id.txt

SECURITY_GROUP_ID=$(cat /tmp/sg_id.txt)

if [[ "$SECURITY_GROUP_ID" != "unknown" && "$SECURITY_GROUP_ID" != "None" ]]; then
    echo "Found bastion security group: $SECURITY_GROUP_ID"
    
    # Add rule for port 9095
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 9095 \
        --cidr 0.0.0.0/0 2>/dev/null || echo "Security group rule may already exist"
    
    echo "✅ Security group configured for port 9095"
else
    echo "⚠️ Could not find bastion security group automatically"
    echo "   Manual setup may be required to open port 9095"
fi

# Store bastion service URL for test steps - use PRIVATE IP for internal cluster access
BASTION_SERVICE_URL="http://$BASTION_PRIVATE_IP:9095/"
echo "$BASTION_SERVICE_URL" > "$SHARED_DIR/egress-health-check-url"

# Also save both public and private IPs for reference
echo "$BASTION_PUBLIC_IP" > "$SHARED_DIR/bastion_public_ip"
echo "$BASTION_PRIVATE_IP" > "$SHARED_DIR/bastion_private_ip"

echo "✅ External IP echo service deployed successfully!"
echo "   Internal Service URL (for cluster): $BASTION_SERVICE_URL"
echo "   External Service URL (for manual testing): http://$BASTION_PUBLIC_IP:9095/"
echo "   This service will report actual source IPs for egress IP validation"
echo ""
echo "🔧 Manual validation available:"
echo "   curl http://$BASTION_PUBLIC_IP:9095/ (from external)"
echo "   curl $BASTION_SERVICE_URL (from cluster pods)"
echo ""
echo "📊 Configuration Summary"
echo "   Bastion Public IP: $BASTION_PUBLIC_IP"
echo "   Bastion Private IP: $BASTION_PRIVATE_IP"
echo "   Service Port: 9095"
echo "   Service Container: quay.io/openshifttest/ip-echo:1.2.0"
echo "   Internal URL for cluster: $BASTION_SERVICE_URL"
echo ""
echo "External IP echo service setup completed successfully!"