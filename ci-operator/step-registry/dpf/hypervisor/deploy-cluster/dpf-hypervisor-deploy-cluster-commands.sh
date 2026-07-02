#!/bin/bash
set -euo pipefail

echo "Checking access to SHARED_DIR ..."
echo "Testing SHARED_DIR" > ${SHARED_DIR}/testing.txt
ls -ltra ${SHARED_DIR}
cat ${SHARED_DIR}/testing.txt

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
# This needs to be main branch
OPENSHIFT_DPF_BRANCH="main"
OPENSHIFT_DPF_GITHUB_REPO_URL="https://github.com/rh-ecosystem-edge/openshift-dpf.git"
CLUSTER_NAME="doca8"
REMOTE_MAIN_WORK_DIR="/root/${CLUSTER_NAME}/ci"

# Check if target bastion is in maintenance mode
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -f /root/${CLUSTER_NAME}/pause"; then
  echo "The cluster is in maintenance mode. Remove the file /root/${CLUSTER_NAME}/pause in the bastion host when the maintenance is over"
  exit 1
fi

# store last openshift-dpf install dir on hypervisor
REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION="/root/doca8/ci/last-openshift-dpf-dir.sh"

echo "Deploying OpenShift cluster with DPF on host ${REMOTE_HOST}"
echo "Remote Main Working directory on hypervisor: ${REMOTE_MAIN_WORK_DIR}"
echo "Cluster name: ${CLUSTER_NAME}"

# Verify remote work directory exists
echo "Verifying remote work directory exists..."
if ! ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -d ${REMOTE_MAIN_WORK_DIR}"; then
  echo "ERROR: Remote work directory ${REMOTE_MAIN_WORK_DIR} does not exist on ${REMOTE_HOST}"
  exit 1
fi
echo "Remote work directory verified: ${REMOTE_MAIN_WORK_DIR}"

# logs directory for artifacts on the remote host
REMOTE_LOGS_DIR="${REMOTE_MAIN_WORK_DIR}/deployment-logs"
echo "Remote logs directory on hypervisor: ${REMOTE_LOGS_DIR}"

datetime_string=$(date +"%Y-%m-%d_%H-%M-%S")

CLEAN_ALL_LOG="${REMOTE_LOGS_DIR}/make_clean-all_${datetime_string}.log"
echo "Remote make clean-all logs directory on hypervisor: ${CLEAN_ALL_LOG}"

DEPLOYMENT_LOG="${REMOTE_LOGS_DIR}/make_all_${datetime_string}.log"
echo "Remote deployment logs directory on hypervisor: ${DEPLOYMENT_LOG}"


# Git clone the dpf-openshift repo on hypervisor
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "ls -ltr; \
  env; \
  cd ${REMOTE_MAIN_WORK_DIR}; \
  mkdir -p openshift-dpf-${datetime_string}; \
  cd openshift-dpf-${datetime_string}; \
  git clone -b ${OPENSHIFT_DPF_BRANCH} ${OPENSHIFT_DPF_GITHUB_REPO_URL}"; then
  # need more checks to ensure repo was git cloned successfully
  echo "Git clone openshift-dpf repo was successful"
else
  echo "Git clone openshift-dpf repo failed"
  exit 1
fi

# If running in a PR job for openshift-dpf, checkout the PR branch
if [[ -n "${PULL_NUMBER:-}" ]] && [[ "${REPO_NAME:-}" == "openshift-dpf" ]]; then
  echo "PR job detected: checking out PR #${PULL_NUMBER} on the remote host"
  if ssh ${SSH_OPTS} root@${REMOTE_HOST} "cd ${REMOTE_MAIN_WORK_DIR}/openshift-dpf-${datetime_string}/openshift-dpf; \
    git fetch origin pull/${PULL_NUMBER}/head:pr-${PULL_NUMBER}; \
    git checkout pr-${PULL_NUMBER}; \
    git rebase ${OPENSHIFT_DPF_BRANCH}"; then
    echo "Successfully checked out PR #${PULL_NUMBER}"
  else
    echo "ERROR: Failed to checkout PR #${PULL_NUMBER}"
    exit 1
  fi
fi

REMOTE_WORK_DIR="${REMOTE_MAIN_WORK_DIR}/openshift-dpf-${datetime_string}"
echo "Remote Working directory on hypervisor: ${REMOTE_WORK_DIR}"

echo "Checking if github repo branch was cloned successfully"
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "ls -ltr; \
  env; \
  cd ${REMOTE_WORK_DIR}/openshift-dpf; \
  git status; \
  git log -1"; then
  echo "Git repository verified successfully"
else
  echo "ERROR: Failed to verify git repository at ${REMOTE_WORK_DIR}/openshift-dpf"
  exit 1
fi

echo "Verify last-openshift-dpf-dir.sh file exists..."
if ! ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -f ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"; then
  echo "WARNING: File ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION} does not exist, creating it..."
  if ! ssh ${SSH_OPTS} root@${REMOTE_HOST} "echo 'LAST_OPENSHIFT_DPF=${REMOTE_WORK_DIR}/openshift-dpf' > ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"; then
    echo "ERROR: Failed to create ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}"
    exit 1
  fi
  echo "File created successfully"
else
  echo "Update hypervisor file ${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION} with path to latest openshift-dpf install dir"
  if ssh ${SSH_OPTS} root@${REMOTE_HOST} "cd ${REMOTE_MAIN_WORK_DIR}; \
    sed -i 's|LAST_OPENSHIFT_DPF=.*|LAST_OPENSHIFT_DPF=${REMOTE_WORK_DIR}/openshift-dpf|' last-openshift-dpf-dir.sh"; then
    echo "Updated variable LAST_OPENSHIFT_DPF with path '${REMOTE_WORK_DIR}/openshift-dpf' in hypervisor file '${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}'"
  else
    echo "ERROR: Failed to update variable LAST_OPENSHIFT_DPF in hypervisor file '${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION}'"
    exit 1
  fi
fi

# Generate the .env file using the env.user file on hypervisor
echo "Verify env.user_${CLUSTER_NAME} source file exists on hypervisor ..."
if ! ssh ${SSH_OPTS} root@${REMOTE_HOST} "test -f ${REMOTE_MAIN_WORK_DIR}/env/env.user_${CLUSTER_NAME}"; then
  echo "ERROR: File env.user_${CLUSTER_NAME} file does not exist: ${REMOTE_MAIN_WORK_DIR}/env/env.user_${CLUSTER_NAME}"
  exit 1
fi

echo "File ${REMOTE_MAIN_WORK_DIR}/env/env.user_${CLUSTER_NAME} was found on hypervisor"

echo "Copy the env.user file in ${REMOTE_MAIN_WORK_DIR}/env to ${REMOTE_WORK_DIR}/openshift-dpf, source the file, then generate .env file"
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "cp ${REMOTE_MAIN_WORK_DIR}/env/env.user_${CLUSTER_NAME} ${REMOTE_WORK_DIR}/openshift-dpf; \
  cd ${REMOTE_WORK_DIR}/openshift-dpf; \
  pwd; \
  env; \
  set -a; \
  source env.user_${CLUSTER_NAME}; \
  env; \
  set +a; \
  make generate-env; \
  ls -ltra .env; \
  cat .env"; then
  echo ".env file from sourced env.user_${CLUSTER_NAME} was generated successfully"
else
  echo "ERROR: Failed to generate .env file from sourced env.user_${CLUSTER_NAME} file"
  exit 1
fi

echo "Create logs dir on the remote host"
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "mkdir -p ${REMOTE_LOGS_DIR}; cd ${REMOTE_LOGS_DIR}; pwd"; then
  echo "Logs directory created successfully at ${REMOTE_LOGS_DIR}"
else
  echo "ERROR: Failed to create logs directory at ${REMOTE_LOGS_DIR}"
  exit 1
fi

echo "Updating variables to use correct file paths with timestamps in .env file"
# Using delimiter '|' since we have '/' in the patterns
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "cd ${REMOTE_WORK_DIR}/openshift-dpf; sed -i 's|KUBECONFIG=.*|KUBECONFIG=${REMOTE_WORK_DIR}/openshift-dpf/kubeconfig-mno|' ${REMOTE_WORK_DIR}/openshift-dpf/.env"; then
  echo "KUBECONFIG variable updated successfully in .env file"
else
  echo "ERROR: Failed to update KUBECONFIG variable in .env file"
  exit 1
fi


# SSH session to hypervisor
echo "Starting DPF deployment with 'make all'..."
echo "Logs will be saved to: ${DEPLOYMENT_LOG}"


# Execute `make clean-all` on hypervisor with comprehensive logging
if ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -euo pipefail; \
  ls -ltr; \
  env; \
  cd ${REMOTE_WORK_DIR}/openshift-dpf ; \
  mkdir -p ${REMOTE_LOGS_DIR} ; \
  make clean-all 2>&1 | tee ${CLEAN_ALL_LOG}"; then

  CLEAN_ALL_SUCCESS=true
  echo "DPF pre-deployment clean-all completed successfully.  CLEAN_ALL_SUCCESS is set to: ${CLEAN_ALL_SUCCESS}"

  echo "Sleeping for 300 seconds ...."
  sleep 300

  # Execute make all on hypervisor with comprehensive logging
  echo "Execute make all on hypervisor with comprehensive logging"

  if ssh ${SSH_OPTS} root@${REMOTE_HOST} "set -euo pipefail; \
    cd ${REMOTE_WORK_DIR}/openshift-dpf ; \
    mkdir -p ${REMOTE_LOGS_DIR} ; \
    make all 2>&1 | tee ${DEPLOYMENT_LOG}"; then

    DEPLOYMENT_SUCCESS=true

    # Note:  here we often get here but make all failed, so we need to ssh again
    # and run oc commands to confirm the deployment is success and we got the DPU workers ready

    echo "DPF deployment completed successfully, DEPLOYMENT_SUCCESS is set to: ${DEPLOYMENT_SUCCESS}"

  else
    DEPLOYMENT_SUCCESS=false
    echo "ERROR: DPF deployment failed, DEPLOYMENT_SUCCESS is set to: ${DEPLOYMENT_SUCCESS}"
    echo "Check deployment logs at: ${DEPLOYMENT_LOG}"
    exit 1
  fi

else
  CLEAN_ALL_SUCCESS=false
  echo "DPF pre-deployment clean-all failed, CLEAN_ALL_SUCCESS is set to: ${CLEAN_ALL_SUCCESS}"
  exit 1
fi

# To Do: add basic oc commands to verify make all step passed

