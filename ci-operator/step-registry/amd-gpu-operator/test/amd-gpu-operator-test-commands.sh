#!/bin/bash
set -euo pipefail

# Setup SSH key
cp /var/run/amd-ci/id_rsa /tmp/id_rsa
chmod 600 /tmp/id_rsa
mkdir -p ~/.ssh
cat > ~/.ssh/config <<EOF
Host ${REMOTE_HOST}
    User root
    IdentityFile /tmp/id_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
chmod 600 ~/.ssh/config

# Wait for cluster API to be ready on remote host
echo "Waiting for cluster API to be ready on remote host..."
API_READY=false
for i in {1..60}; do
  if ssh "root@${REMOTE_HOST}" "curl -k -s --connect-timeout 5 https://${API_IP}:6443/readyz" | grep -q "ok"; then
    echo "Cluster API is ready!"
    API_READY=true
    break
  fi
  echo "Waiting for API... ($i/60)"
  sleep 10
done

if [[ "${API_READY}" != "true" ]]; then
  echo "ERROR: Cluster API failed to become ready within timeout (10 minutes)"
  exit 1
fi

# Fetch kubeconfig from remote host
scp "root@${REMOTE_HOST}:/root/kubeconfig" /tmp/kubeconfig

# Rewrite kubeconfig to use localhost (via SSH tunnel)
# Use a regex to match any server URL — handles both IP-based and hostname-based
# entries, including snapshot-modified cluster names (e.g. ocp-419)
sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|g' /tmp/kubeconfig
sed -i '/certificate-authority-data:/d' /tmp/kubeconfig
sed -i '/server: https:\/\/127.0.0.1:6443/a\    insecure-skip-tls-verify: true' /tmp/kubeconfig

# Establish SSH tunnel to cluster API
ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
    -L "6443:${API_IP}:6443" "root@${REMOTE_HOST}" -N -f

# Verify tunnel is working
echo "Verifying SSH tunnel to cluster API..."
for i in {1..10}; do
  if curl -k -s --connect-timeout 5 https://127.0.0.1:6443/readyz 2>/dev/null | grep -q "ok"; then
    echo "SSH tunnel established successfully!"
    break
  fi
  if [[ $i -eq 10 ]]; then
    echo "ERROR: SSH tunnel failed to establish within timeout"
    exit 1
  fi
  echo "Waiting for tunnel... ($i/10)"
  sleep 2
done

# Run AMD GPU verification tests
export KUBECONFIG=/tmp/kubeconfig
make test-gpu
