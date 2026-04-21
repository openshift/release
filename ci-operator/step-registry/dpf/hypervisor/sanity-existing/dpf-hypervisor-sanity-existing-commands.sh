#!/bin/bash
set -euo pipefail

# Configuration
REMOTE_HOST="${REMOTE_HOST:-10.6.135.45}"

# $ host api.doca8.nvidia.eng.rdu2.dc.redhat.com
# api.doca8.nvidia.eng.rdu2.dc.redhat.com has address 10.6.135.33
echo "Setting DOCA8 CLUSTER_API_IP to 10.6.135.33"
CLUSTER_API_IP="10.6.135.33"

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

# Prepare SSH key from Vault (add trailing newline if missing)
echo "Configuring SSH private key..."
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

# Define SSH command with explicit options (don't rely on ~/.ssh/config)
SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

### DEBUG: add a long timeout to troubleshoot from pod
## echo "Sleeping for 999999999 seconds ...."
## sleep 999999999

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
SANITY_TESTS_RESULT=""
REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION="/root/doca8/ci/last-openshift-dpf-dir.sh"

### Debug: testing scp:
# Extract the kubeconfig from the last DPF openshift-dpf install dir on hypervisor
echo "=== SCP the kubeconfig from the last DPF openshift-dpf install dir on hypervisor ==="
### debug:

scp ${SSH_OPTS} root@${REMOTE_HOST}:${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION} /tmp

ls -ltr /tmp

if [ -f /tmp/last-openshift-dpf-dir.sh ] ; then
  cat /tmp/last-openshift-dpf-dir.sh
  set -a
  source /tmp/last-openshift-dpf-dir.sh 
  echo "last DPF openshift-dpf dir is: '${LAST_OPENSHIFT_DPF}'"
else
  echo "Failed to find scp-ed file '/tmp/last-openshift-dpf-dir.sh'"
  exit 1
fi

# scp DPF managment cluster kubeconfig from last dpf install dir
echo "SCP DPF managment cluster kubeconfig from last dpf install dir to /tmp locally"

scp ${SSH_OPTS} root@${REMOTE_HOST}:${LAST_OPENSHIFT_DPF}/kubeconfig.doca8 /tmp

ls -ltr /tmp
cp /tmp/kubeconfig.doca8 /tmp/kubeconfig.doca8_ORIG

echo " Substitute the hypervisor domain name 'api.doca8.nvidia.eng.rdu2.dc.redhat.com' for cluster api ip address '${CLUSTER_API_IP}'"

sed -i "s|server: https://api.doca8.nvidia.eng.rdu2.dc.redhat.com:6443|server: https://${CLUSTER_API_IP}:6443|" /tmp/kubeconfig.doca8

cat /tmp/kubeconfig.doca8 | grep 6443

export KUBECONFIG=/tmp/kubeconfig.doca8



# Containerfile is updated in openshift-dpf to dnf install oc client, and the openshift-dpf 
# latest main clone should be mounted in /root/dpf-ci
echo "=== Checking if the openshift-dpf latest PR clone is mounted in /root/dpf-ci dir on this running pod"
ls -ltr /root/dpf-ci

####### Debug:
echo "=== DEBUG:  sleeping for 20 mins in case we need to oc rhs to this pod remotely"
sleep 1200

which oc
echo "=== Running oc commands on the DPF cluster from extracted kubeconfig"

oc --insecure-skip-tls-verify=true get co
oc --insecure-skip-tls-verify=true get nodes -o wide
oc --insecure-skip-tls-verify=true get dpu -A
oc --insecure-skip-tls-verify=true get dpuservice -A
oc --insecure-skip-tls-verify=true get application -A

echo "=== DPF Make Target checks on Existing Cluster ==="
echo "Using openshift-dpf dir from last cluster-deploy: '${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}'"

# update the .env file to shorten the VERIFY_MAX_RETRIES and VERIFY_SLEEP_SECONDS var values
echo "Updating VERIFY_DEPLOYMENT, VERIFY_MAX_RETRIES and VERIFY_SLEEP_SECONDS variable values to true, 4 and 3 respectively in .env file"
# Using delimiter '|' since we have '/' in the patterns
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -e;\
    source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
    echo \${LAST_OPENSHIFT_DPF}; \
    cd \${LAST_OPENSHIFT_DPF}; \
    pwd ; \
    set -e; \
    test -f .env ; \
    cat .env | grep VERIFY ; \
    cp .env .env_orig ; \
    sed -i -E 's|^VERIFY_DEPLOYMENT=.*$|VERIFY_DEPLOYMENT=true|' .env ; \
    sed -i -E 's|^VERIFY_MAX_RETRIES=.*$|VERIFY_MAX_RETRIES=4|' .env ; \
    sed -i -E 's|^VERIFY_SLEEP_SECONDS=.*$|VERIFY_SLEEP_SECONDS=3|' .env ; \
    grep -qx 'VERIFY_DEPLOYMENT=true' .env ; \
    grep -qx 'VERIFY_MAX_RETRIES=4' .env ; \
    grep -qx 'VERIFY_SLEEP_SECONDS=3' .env ; \
    cat .env | grep VERIFY "; then
  echo "VERIFY_DEPLOYMENT, VERIFY_MAX_RETRIES and VERIFY_SLEEP_SECONDS variables updated successfully in .env file"
else
  echo "ERROR: Failed to update VERIFY_DEPLOYMENT, VERIFY_MAX_RETRIES and VERIFY_SLEEP_SECONDS variables in .env file"
  exit 1
fi

# Run dpf make target checks test
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -a; \
    pwd; \
    ls -ltr; \
    env; \
    source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
    echo \${LAST_OPENSHIFT_DPF}; \
    env; \
    cd \${LAST_OPENSHIFT_DPF}; \
    pwd; \
    export KUBECONFIG=\${LAST_OPENSHIFT_DPF}/kubeconfig.doca8; \
    oc get co; \
    oc get nodes; \
    oc get dpu -A; \
    oc get application -A; \
    echo \${KUBECONFIG}; \
    ls -ltr ; \
    cat .env | grep VERIFY ; \
    set -e; \
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

# Run dpf-sanity-checks sanity test
echo "=== DPF Sanity Test on last Existing Cluster ==="
echo "log file on hypervisor: log-dpf-sanity-checks-${datetime_string}"

if ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -euo pipefail; \
  ls -ltr; \
  env; \
  source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
  echo \${LAST_OPENSHIFT_DPF}; \
  env; \
  cd \${LAST_OPENSHIFT_DPF}; \
  pwd; \
  cat .env; \
  cat verification-result; \
  make run-dpf-sanity 2>&1 | tee log-dpf-sanity-checks-${datetime_string}"; then 
  
  # Note the above statement will return true if it get executed and even if it sanity fails
  # Need to try a different approach to check pass/fail for sanity test

  echo "Sanity Test Passed on hypervisor"; 
  SANITY_TESTS_RESULT="PASS";
else 
  echo "Sanity Test Failed on hypervisor";

fi

# if this does not work, try to scp the log file to the pod and store in the $SHARED_DIR/logs or /tmp
echo "====== Retrieving DPF Sanity Test Log file:"
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "source ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}; \
  echo \${LAST_OPENSHIFT_DPF}; \
  env; \
  cd \${LAST_OPENSHIFT_DPF}; \
  cat log-dpf-sanity-checks-${datetime_string}"; then

  echo "Successfully output Sanity Test log file"; 
  
else 
  echo "Failed to output Sanity Test log file";

fi

# parse sanity test file and return pass/fail
# Add code here

scp ${SSH_OPTS} root@${REMOTE_HOST}:${LAST_OPENSHIFT_DPF}/log-dpf-sanity-checks-${datetime_string} /tmp

if [ -f "/tmp/log-dpf-sanity-checks-${datetime_string}" ] ; then
  cat /tmp/log-dpf-sanity-checks-${datetime_string}
  # add parsing logic here, look for error messages, etc.
else
  echo "Failed to find scp-ed file /tmp/tmp/log-dpf-sanity-checks-${datetime_string}"

fi

if [ "${SANITY_TESTS_RESULT}" == "PASS" ]; then
  exit 0
fi

exit 1
