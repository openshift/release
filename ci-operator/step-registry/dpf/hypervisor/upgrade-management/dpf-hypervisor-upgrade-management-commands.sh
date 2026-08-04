#!/bin/bash
set -euo pipefail

# SSH + cluster-locate boilerplate copied from dpf-hypervisor-sanity-existing-commands.sh.
# Duplicated because each step ref runs as an independent pod with no shared setup.
# Also duplicated in network-tests and deploy-cluster. TODO: extract into a shared script.
REMOTE_HOST="${REMOTE_HOST:-10.6.135.45}"
REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION="/root/doca8/ci/last-openshift-dpf-dir.sh"

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

cat /var/run/dpf-ci/private-key | base64 -d >/tmp/id_rsa
echo "" >>/tmp/id_rsa
chmod 600 /tmp/id_rsa

SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

echo "Testing SSH connection to ${REMOTE_HOST}..."
if ! ssh ${SSH_OPTS} root@${REMOTE_HOST} echo 'SSH connection successful'; then
	echo "ERROR: Failed to connect to hypervisor ${REMOTE_HOST}"
	echo "Debug information:"
	ls -la /tmp/id_rsa
	ssh -v ${SSH_OPTS} root@${REMOTE_HOST} echo 'test' || true
	exit 1
fi

echo "=== Locating last deployed cluster ==="
scp ${SSH_OPTS} root@${REMOTE_HOST}:${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION} /tmp

if [[ ! -f /tmp/last-openshift-dpf-dir.sh ]]; then
	echo "ERROR: Failed to retrieve last-openshift-dpf-dir.sh from hypervisor"
	exit 1
fi

cat /tmp/last-openshift-dpf-dir.sh
set -a
source /tmp/last-openshift-dpf-dir.sh
set +a
echo "Last openshift-dpf dir: ${LAST_OPENSHIFT_DPF}"

# The actual step
echo "=== Running management cluster upgrade ==="
ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -euo pipefail; \
    source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
    cd \${LAST_OPENSHIFT_DPF}; \
    export KUBECONFIG=\${LAST_OPENSHIFT_DPF}/kubeconfig.doca8; \
    make upgrade-management"
