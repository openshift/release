#!/bin/bash
set -euo pipefail

# Configuration
REMOTE_HOST="${REMOTE_HOST:-10.6.135.45}"

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

# Prepare SSH key from Vault (add trailing newline if missing)
echo "Configuring SSH private key..."
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

# Define SSH command with explicit options (don't rely on ~/.ssh/config)
SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

# Test SSH connection
echo "Testing SSH connection to ${REMOTE_HOST}..."
if ssh ${SSH_OPTS} root@${REMOTE_HOST} echo 'SSH connection successful'; then
    echo "SSH setup complete and tested successfully"
else
    echo "ERROR: Failed to connect to hypervisor ${REMOTE_HOST}"
    echo "Debug information:"
    echo "- Checking if SSH key exists:"
    ls -la /tmp/id_rsa
    echo "- Testing SSH connectivity with verbose output:"
    ssh -v ${SSH_OPTS} root@${REMOTE_HOST} echo 'test' || true
    exit 1
fi

# Export SSH settings for subsequent steps
echo "REMOTE_HOST=${REMOTE_HOST}" >> ${SHARED_DIR}/dpf-env
echo "SSH_OPTS=${SSH_OPTS}" >> ${SHARED_DIR}/dpf-env
echo "SSH setup completed successfully for ${REMOTE_HOST}"

echo "Remote host: ${REMOTE_HOST}"

datetime_string=$(date +"%Y-%m-%d_%H-%M-%S")
NETWORK_TESTS_RESULT=""

# Run dpf make target checks test
REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION="/root/doca8/ci/last-openshift-dpf-dir.sh"

echo "=== DPF Make Target checks on Existing Cluster ==="
echo "Using openshift-dpf dir from last cluster-deploy: '${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}'"

echo "Updating VERIFY_DEPLOYMENT, VERIFY_MAX_RETRIES and VERIFY_SLEEP_SECONDS variable values to true, 4 and 3 respectively in .env file"
# Using delimiter '|' since we have '/' in the patterns
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -e; \
    test -f ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
    source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
    echo \${LAST_OPENSHIFT_DPF}; \
    cd \${LAST_OPENSHIFT_DPF}; \
    pwd ; \
    set -e; \
    test -f .env ; \
    cat .env | grep VERIFY ; \
    cp .env .env_orig ; \
    sed -i 's|VERIFY_DEPLOYMENT=.*|VERIFY_DEPLOYMENT=true|' .env ; \
    sed -i 's|VERIFY_MAX_RETRIES=.*|VERIFY_MAX_RETRIES=4|' .env ; \
    sed -i 's|VERIFY_SLEEP_SECONDS=.*|VERIFY_SLEEP_SECONDS=3|' .env ; \
    cat .env | grep VERIFY"; then
  echo "VERIFY_DEPLOYMENT, VERIFY_MAX_RETRIES and VERIFY_SLEEP_SECONDS variables updated successfully in .env file"
else
  echo "ERROR: Failed to update VERIFY_DEPLOYMENT, VERIFY_MAX_RETRIES and VERIFY_SLEEP_SECONDS variables in .env file"
  exit 1
fi

##if ssh ${SSH_OPTS} root@${REMOTE_HOST} "

if ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -a; \
    pwd; \
    ls -ltr; \
    env; \
    source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
    echo \${LAST_OPENSHIFT_DPF}; \
    env; \
    cd \${LAST_OPENSHIFT_DPF}; \
    pwd; \
    set -e;\
    export KUBECONFIG=\${LAST_OPENSHIFT_DPF}/kubeconfig.doca8; \
    oc get co; \
    oc get nodes; \
    oc get dpu -A; \
    oc get application -A; \
    echo \${KUBECONFIG}; \
    ls -ltr ; \
    make verify-workers; \
    make verify-dpu-nodes; \
    make verify-deployment; \
    make verify-dpudeployment; \
    echo \$? > verification-result"; then

  echo "DPF spot check tests Passed"; 

else 
  echo "DPF spot checks tests Failed"; 
  exit 1
fi



echo "=== Run DPF Kubernetes Traffic Flow Tests on Existing Cluster ==="
# Run kubernetes traffic flow test
# Need to run cmds or script on hypervisor to discover worker node names after being renamed
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -euo pipefail; \
  ls -ltr; \
  env; \
  source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
  echo \${LAST_OPENSHIFT_DPF}; \
  env; \
  cd \${LAST_OPENSHIFT_DPF}; \
  cat .env; \
  export TFT_SERVER_NODE=worker-303ea712f414; \
  export TFT_CLIENT_NODE=worker-303ea712f378; \
  make run-traffic-flow-tests 2>&1 | tee log-traffic-flow-tests-${datetime_string}"; then

  echo "Kubernetes Network Traffic Flow Iperf Tests Passed";
  NETWORK_TESTS_RESULT="PASS"

else 
  echo "Kubernetes Network Traffic Flow Iperf Tests Failed";

fi

echo "====== Output DPF Kubernetes Traffic Flow Tests Log file:"
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
  echo \${LAST_OPENSHIFT_DPF}; \
  env; \
  cd \${LAST_OPENSHIFT_DPF}; \
  cat log-traffic-flow-tests-${datetime_string}"; then

  echo "Successfully output Kubernetes Network Traffic Flow Iperf Tests logs"; 

else 
  echo "Failed to output DPF kubernetes Traffic Flow Iperf Tests logs";

fi

# Parse the log files, may need to scp to container running ssh cmds and process the 
# output file and exit accordingly

if [ "${NETWORK_TESTS_RESULT}" == "PASS" ]; then
  exit 0
fi

exit 1

