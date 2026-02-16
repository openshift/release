#!/bin/bash
set -euo pipefail

# Load environment
# commented
## source ${SHARED_DIR}/dpf-env

# Configuration
REMOTE_HOST="${REMOTE_HOST:-10.6.135.45}"
echo "Remote host: ${REMOTE_HOST}"

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

# Prepare SSH key from Vault (add trailing newline if missing)
echo "Configuring SSH private key..."
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

# Define SSH command with explicit options (don't rely on ~/.ssh/config)
SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

### DEBUG: add a ong timeout to troubleshoot from pod
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

# Bypassing env vars set in prepare-environment for now
OPENSHIFT_DPF_BRANCH="dpf-25.10"
OPENSHIFT_DPF_GITHUB_REPO_URL="https://github.com/rh-ecosystem-edge/openshift-dpf.git"
CLUSTER_NAME="doca8"
REMOTE_WORK_DIR="/root/${CLUSTER_NAME}/ci"
ENV_FILE="/root/${CLUSTER_NAME}/ci/.env_${CLUSTER_NAME}"

CLUSTER_NAME="doca8"


echo "Deploying OpenShift cluster with DPF on host ${REMOTE_HOST}"
echo "Remote Working directory on hypervisor: ${REMOTE_WORK_DIR}"
echo "Cluster name: ${CLUSTER_NAME}"
echo "Env file: ${ENV_FILE}"


# Create logs directory for artifacts
## LOGS_DIR="${ARTIFACT_DIR}/deployment-logs"
LOGS_DIR="${REMOTE_WORK_DIR}/ci/deployment-logs"
mkdir -p ${LOGS_DIR}

datetime_string=$(date +"%Y-%m-%d_%H-%M-%S")

# Start deployment with logging
## DEPLOYMENT_LOG="${REMOTE_WORK_DIR}/logs/make_all_$(date +%Y%m%d_%H%M%S).log"
DEPLOYMENT_LOG="${REMOTE_WORK_DIR}/logs/make_all_${datetime_string}.log"

# Git clone the dpf-openshift repo on hypervisor
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "ls -ltr; env; cd ${REMOTE_WORK_DIR}; mkdir -p openshift-dpf-${datetime_string}; cd openshift-dpf-${datetime_string}; git clone -b ${OPENSHIFT_DPF_BRANCH} ${OPENSHIFT_DPF_GITHUB_REPO_URL}"; then
  echo "Git clone openshift-dpf repo was successful"
else
  echo "Git clone openshift-dpf repo failed"
fi

echo "Checking if github repo branch was cloned successfully"
ssh ${SSH_OPTS} root@${REMOTE_HOST} "ls -ltr; env; cd ${REMOTE_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf; git status"

echo "Copy the .env file in ${REMOTE_WORK_DIR}/env to ${REMOTE_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf"
ssh ${SSH_OPTS} root@${REMOTE_HOST} "cp ${REMOTE_WORK_DIR}/env/.env_${CLUSTER_NAME} ${REMOTE_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf/.env; cat ${REMOTE_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf/.env"

# Using delimiter '|' since we have '/' in the patterns
ssh ${SSH_OPTS} root@${REMOTE_HOST} "cd ${REMOTE_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf; sed -i 's|KUBECONFIG=.*|KUBECONFIG=${REMOTE_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf/kubeconfig-mno|' ${REMOTE_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf/.env"

### DEBUG: add a ong timeout to troubleshoot from pod
echo "Sleeping for 999999999 seconds ...."
sleep 999999999

exit 1

######### Below remove or comment to make sure you are able to cloning the repo

### NOTE:  need to run make clean-all to delete the VMs before make all !!!!

########### comment make all for now

########### need to update the path for KUBECONFIG in the ,env file

#### Global comment:
: <<'GLOBALCOMMENT'
# SSH session to 
echo "Starting DPF deployment with 'make all'..."
echo "Logs will be saved to: ${DEPLOYMENT_LOG}"

# Execute make all on hypervisor with comprehensive logging
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "cd ${REMOTE_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf && mkdir -p logs && make all 2>&1 | tee ${DEPLOYMENT_LOG}"; then
    echo "DPF deployment completed successfully"
    DEPLOYMENT_SUCCESS=true
else
    echo "DPF deployment failed"
    DEPLOYMENT_SUCCESS=false
fi

# Copy deployment logs back for analysis
echo "Copying deployment logs for artifact collection..."
scp -r ${REMOTE_HOST}:${REMOTE_WORK_DIR}/logs/* ${LOGS_DIR}/ || echo "Some logs could not be copied"

# Copy kubeconfig if deployment succeeded
if [[ "${DEPLOYMENT_SUCCESS}" == "true" ]]; then
    echo "Copying kubeconfig from hypervisor..."
    
    # Check for kubeconfig files
    if ssh ${REMOTE_HOST} "cd ${REMOTE_WORK_DIR} && test -f kubeconfig"; then
        scp ${REMOTE_HOST}:${REMOTE_WORK_DIR}/kubeconfig ${SHARED_DIR}/kubeconfig
        echo "Kubeconfig copied successfully"
    elif ssh ${REMOTE_HOST} "cd ${REMOTE_WORK_DIR} && test -f ${CLUSTER_NAME}.kubeconfig"; then
        scp ${REMOTE_HOST}:${REMOTE_WORK_DIR}/${CLUSTER_NAME}.kubeconfig ${SHARED_DIR}/kubeconfig
        echo "Kubeconfig copied successfully"
    else
        echo "WARNING: Could not find kubeconfig file"
        ssh ${REMOTE_HOST} "cd ${REMOTE_WORK_DIR} && ls -la *.kubeconfig kubeconfig" || echo "No kubeconfig files found"
        DEPLOYMENT_SUCCESS=false
    fi
else
    echo "Deployment failed, skipping kubeconfig copy"
fi

# Validate cluster accessibility if kubeconfig exists
if [[ "${DEPLOYMENT_SUCCESS}" == "true" && -f ${SHARED_DIR}/kubeconfig ]]; then
    echo "Validating cluster accessibility..."
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
    
    # Test cluster connectivity
    if oc get nodes &>/dev/null; then
        echo "Cluster is accessible via kubeconfig"
        
        # Get basic cluster info for artifacts
        oc get nodes > ${LOGS_DIR}/cluster-nodes.txt
        oc get co > ${LOGS_DIR}/cluster-operators.txt || echo "Could not get cluster operators"
        oc version > ${LOGS_DIR}/cluster-version.txt || echo "Could not get cluster version"
        
        echo "Cluster validation completed successfully"
    else
        echo "ERROR: Cannot access cluster with provided kubeconfig"
        DEPLOYMENT_SUCCESS=false
    fi
fi

# Collect hypervisor status for debugging
echo "Collecting hypervisor status for artifacts..."
ssh ${REMOTE_HOST} "df -h" > ${LOGS_DIR}/hypervisor-disk-usage.txt || true
ssh ${REMOTE_HOST} "free -h" > ${LOGS_DIR}/hypervisor-memory-usage.txt || true
ssh ${REMOTE_HOST} "virsh list --all" > ${LOGS_DIR}/hypervisor-vms.txt || true

# Export deployment status for test steps
echo "DEPLOYMENT_SUCCESS=${DEPLOYMENT_SUCCESS}" >> ${SHARED_DIR}/dpf-env



# Final status check
if [[ "${DEPLOYMENT_SUCCESS}" == "true" ]]; then
    echo "DPF deployment completed successfully!"
    echo "Cluster: ${CLUSTER_NAME}"
    echo "Kubeconfig available at: ${SHARED_DIR}/kubeconfig"
    echo "Ready for testing..."
else
    echo "💥 DPF deployment failed!"
    echo "Check logs in: ${LOGS_DIR}/"
    echo "Remote logs: ${REMOTE_WORK_DIR}/logs/"
    exit 1
fi

## end ofg global multi-line comment
GLOBALCOMMENT
