#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit

REMOTE_HOST="${REMOTE_HOST:-10.6.135.45}"
CLUSTER_NAME=$(cat "${CLUSTER_PROFILE_DIR}/cluster-name")
PROXY_PORT=8213

cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa
SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

echo "Testing SSH to ${REMOTE_HOST}..."
ssh ${SSH_OPTS} root@${REMOTE_HOST} echo 'SSH OK'

# Find the last openshift-dpf install dir on the hypervisor
REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION="/root/${CLUSTER_NAME}/ci/last-openshift-dpf-dir.sh"
scp ${SSH_OPTS} root@${REMOTE_HOST}:${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION} /tmp
set -a
source /tmp/last-openshift-dpf-dir.sh
set +a
echo "Install dir: ${LAST_OPENSHIFT_DPF}"

# Deploy proxy and produce kubeconfig with ingress CA on the hypervisor
ssh ${SSH_OPTS} root@${REMOTE_HOST} "cd ${LAST_OPENSHIFT_DPF} && make deploy-proxy"

# Copy the kubeconfig it produced
scp ${SSH_OPTS} root@${REMOTE_HOST}:${LAST_OPENSHIFT_DPF}/kubeconfig.proxy "${SHARED_DIR}/kubeconfig"

# Write proxy-conf.sh (sourced automatically by openshift-e2e-test)
sed -e "s/\${REMOTE_HOST}/${REMOTE_HOST}/g" \
    -e "s/\${PROXY_PORT}/${PROXY_PORT}/g" \
    /root/dpf-ci/ci/proxy-conf.sh.template >"${SHARED_DIR}/proxy-conf.sh"

echo "Done — proxy at ${REMOTE_HOST}:${PROXY_PORT}, kubeconfig copied to ${SHARED_DIR}"
