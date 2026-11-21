#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# Create shared functions to SHARED_DIR
#
# TODO(mtulio): move "install functions" to base image, when possible.

echo "Creating shared init file: ${SHARED_DIR}/init-fn.sh"
cat << EOF > "${SHARED_DIR}/init-fn.sh"
export PATH=\${PATH}:/tmp
export KUBECONFIG=\${SHARED_DIR}/kubeconfig

function log() {
  echo "\$(date -u --rfc-3339=seconds) - \$*"
}
export -f log

# Install awscli (python3 only)
function install_awscli() {
  log "Checking/installing awscli..."
  which python || true
  whereis python || true

  if ! command -v aws &> /dev/null
  then
      log "Install AWS cli..."
      export PATH="\${HOME}/.local/bin:\${PATH}"
      if command -v pip3 &> /dev/null
      then
          python -m ensurepip
          pip3 install --user awscli
      else
          if [ "\$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]
          then
            easy_install --user 'pip<21'
            pip install --user awscli
          else
            log "No pip available exiting..."
            exit 1
          fi
      fi
  fi
}
export -f install_awscli

function install_jq() {
  log "Checking/installing jq..."
  if ! command -v jq &> /dev/null; then
      wget -qO /tmp/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
      chmod +x /tmp/jq
  fi
  log "Installing jq done:"
  which jq
}
export -f install_jq

function install_yq3() {
  log "Checking/installing yq3..."
  if ! command -v yq3 &> /dev/null; then
    wget -qO /tmp/yq3 https://github.com/mikefarah/yq/releases/download/3.4.0/yq_linux_amd64
    chmod u+x /tmp/yq3
  fi
  log "Installing yq3 done:"
  which yq3
}
export -f install_yq3

function install_yq4() {
  log "Checking/installing yq4..."
  if ! command -v yq4 &> /dev/null; then
    wget -q -O /tmp/yq4 https://github.com/mikefarah/yq/releases/download/v4.34.1/yq_linux_amd64
    chmod u+x /tmp/yq4
  fi
  log "Installing yq4 done:"
  which yq4
}
export -f install_yq4

function install_butane() {
  log "Checking/installing butane..."
  if ! command -v butane &> /dev/null; then
    wget -q -O /tmp/butane "https://github.com/coreos/butane/releases/download/v0.18.0/butane-x86_64-unknown-linux-gnu"
    chmod u+x /tmp/butane
  fi
  log "Installing butane done:"
  which butane
}
export -f install_butane

function install_oc() {
  log "Checking/installing oc..."
  if ! command -v oc &> /dev/null; then
    cd /tmp && curl -L https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz -o oc.tar.gz && tar xzvf oc.tar.gz
  fi
  log "Installing oc done"
  which oc
}
export -f install_oc

function make_install_dir() {
  export INSTALL_DIR=/tmp
  mkdir -vp \${INSTALL_DIR}/auth || true
  cp -vf \${SHARED_DIR}/kubeconfig \${INSTALL_DIR}/auth/ 2>/dev/null || true
}
export -f make_install_dir

function shared_term_handler() {
  # kill existing subprocess, if any
  CHILDREN=\$(jobs -p);
  if test -n "\${CHILDREN}";
  then
    kill \${CHILDREN} && wait;
  fi
}
export -f shared_term_handler

# gather_bootstrap_via_bastion routes openshift-install gather bootstrap
# through the bastion host so it can reach a private-subnet bootstrap.
# Args: \$1 = SSH key path, \$2 = bootstrap IP (for fallback args)
# Reads: SHARED_DIR/bastion_public_address, bastion_ssh_user,
#         GATHER_BOOTSTRAP_ARGS; writes results to ARTIFACT_DIR.
# All operations are best-effort (|| true) to avoid blocking teardown.
function gather_bootstrap_via_bastion() {
  local ssh_key="\$1"
  local bootstrap_ip="\$2"
  local bastion_dns bastion_user gather_args installer_bin
  bastion_dns=\$(cat "\${SHARED_DIR}/bastion_public_address")
  bastion_user=\$(cat "\${SHARED_DIR}/bastion_ssh_user")
  installer_bin=\$(which openshift-install 2>/dev/null || echo "")
  if [[ -z "\${installer_bin}" ]]; then
    log "[BASTION GATHER]: openshift-install not found, cannot gather"
    return 0
  fi
  if [[ -s "\${SHARED_DIR}/GATHER_BOOTSTRAP_ARGS" ]]; then
    gather_args=\$(cat "\${SHARED_DIR}/GATHER_BOOTSTRAP_ARGS")
  else
    gather_args="--bootstrap \${bootstrap_ip}"
  fi
  local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

  log "[BASTION GATHER]: Routing gather through bastion \${bastion_dns}"

  # Ensure our UID is in /etc/passwd (required for SSH/SCP in CI pods)
  if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
      echo "\${USER_NAME:-default}:x:\$(id -u):0:\${USER_NAME:-default} user:\${HOME}:/sbin/nologin" >> /etc/passwd
    fi
  fi

  # Copy installer binary and SSH key to bastion
  scp \${ssh_opts} -i "\${ssh_key}" "\${installer_bin}" "\${bastion_user}@\${bastion_dns}:/tmp/openshift-install" || true
  scp \${ssh_opts} -i "\${ssh_key}" "\${ssh_key}" "\${bastion_user}@\${bastion_dns}:/tmp/ssh-gatherkey" || true

  # Run gather on bastion with --dir /tmp/gather-dir so output location is known.
  # The key is removed immediately after gather regardless of exit code.
  ssh \${ssh_opts} -i "\${ssh_key}" "\${bastion_user}@\${bastion_dns}" \
    "mkdir -p /tmp/gather-dir; /tmp/openshift-install gather bootstrap --dir /tmp/gather-dir --key /tmp/ssh-gatherkey \${gather_args} --log-level debug 2>/tmp/gather-bootstrap.log; rc=\\\$?; rm -f /tmp/ssh-gatherkey; exit \\\$rc" || true

  # Copy results back to artifact dir
  scp \${ssh_opts} -i "\${ssh_key}" "\${bastion_user}@\${bastion_dns}:/tmp/gather-bootstrap.log" "\${ARTIFACT_DIR}/" 2>/dev/null || true
  scp \${ssh_opts} -i "\${ssh_key}" "\${bastion_user}@\${bastion_dns}:/tmp/gather-dir/log-bundle-*.tar.gz" "\${ARTIFACT_DIR}/" 2>/dev/null || true

  log "[BASTION GATHER]: Completed"
}
export -f gather_bootstrap_via_bastion

# collect_bootstrap_handler is a error handler to collect bootstrap logs
# when the program finished unexpected.
function collect_bootstrap_handler() {
  local handler_name="BOOTSTRAP ERROR HANDLER"
  log "[\${handler_name}]: Starting..."
  if ! [ -f "\${SHARED_DIR}/BOOTSTRAP_IP" ]; then
    log "[ERROR HANDLER] Bootstrap IP not found in \${SHARED_DIR}/BOOTSTRAP_IP, exiting..."
    shared_term_handler
    return
  fi

  # collect bootstrap logs
  BOOTSTRAP_IP=\$(<\${SHARED_DIR}/BOOTSTRAP_IP)
  SSH_PRIV_KEY_PATH=\${CLUSTER_PROFILE_DIR}/ssh-privatekey

  # Try to collect bootstrap logs.
  # When a bastion host is available (disconnected install), the bootstrap
  # is on a private subnet unreachable from the CI runner.  Route the
  # gather through the bastion: copy the installer binary and SSH key to
  # the bastion, run "openshift-install gather bootstrap" there (the
  # bastion can reach private IPs within the VPC), then copy the
  # log-bundle back.  For the connected path (no bastion) the existing
  # direct gather is preserved.
  log "[\${handler_name}]: Attempting to collect bootstrap logs..."
  {
    make_install_dir
    if ! command -v openshift-install &> /dev/null; then
      log "[\${handler_name}]: ERROR: openshift-install not found, cannot gather bootstrap logs"
    elif [[ "\${PLATFORM_EXTERNAL_DISCONNECTED:-no}" == "yes" ]] && [[ -s "\${SHARED_DIR}/bastion_public_address" ]] && [[ -s "\${SHARED_DIR}/bastion_ssh_user" ]]; then
      gather_bootstrap_via_bastion "\${SSH_PRIV_KEY_PATH}" "\${BOOTSTRAP_IP}"
    else
      # Direct gather for connected path (bootstrap has public IP)
      openshift-install gather bootstrap --key "\${SSH_PRIV_KEY_PATH}" --bootstrap "\${BOOTSTRAP_IP}" || true
      cp log-bundle-*.tar.gz "\${ARTIFACT_DIR}" || true
    fi
  } || true

  log "[\${handler_name}]: Completed"
}
export -f collect_bootstrap_handler

function collect_bootstrap_error_handler() {
  # Only run if exiting with an error
  local exit_code=\$?

  log "[BOOTSTRAP HANDLER]: Script is exiting with code \$exit_code"
  if [[ \$exit_code -ne 0 ]]; then
    collect_bootstrap_handler
  fi

  log "[BOOTSTRAP HANDLER]: Completed"
  shared_term_handler

  # Ensure we exit with the original error code
  exit \$exit_code
}
export -f collect_bootstrap_error_handler

EOF
