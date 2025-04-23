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
    cd /tmp && curl -L https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz -o oc.tar.gz && tar xzvf oc.tar.gz
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

  # Try to collect bootstrap logs
  log "[\${handler_name}]: Attempting to collect bootstrap logs..."
  {
    make_install_dir
    if ! command -v openshift-install &> /dev/null; then
      log "[\${handler_name}]: ERROR: openshift-install not found, cannot gather bootstrap logs"
    else
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
