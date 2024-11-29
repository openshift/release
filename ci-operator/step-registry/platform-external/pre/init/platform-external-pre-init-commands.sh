#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# Create shared functions to SHARED_DIR
#
# TODO(mtulio): move "install functions" to base image, when possible.

echo "Creating shared ini file: ${SHARED_DIR}/init-fn.sh"
cat << EOF > "${SHARED_DIR}/init-fn.sh"

export PATH=${PATH}:/tmp

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
  if ! command -v jq; then
      wget -qO /tmp/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
      chmod +x /tmp/jq
  fi
  log "Installing jq done:"
  which jq
}
export -f install_jq

function install_yq3() {
  log "Checking/installing yq3..."
  if ! command -v yq3; then
    wget -qO /tmp/yq3 https://github.com/mikefarah/yq/releases/download/3.4.0/yq_linux_amd64
    chmod u+x /tmp/yq3
  fi
  log "Installing yq3 done:"
  which yq3
}
export -f install_yq3

function install_yq4() {
  log "Checking/installing yq..."
  if ! [ -x "\$(command -v yq4)" ]; then
    wget -q -O /tmp/yq4 https://github.com/mikefarah/yq/releases/download/v4.34.1/yq_linux_amd64
    chmod u+x /tmp/yq4
  fi
  log "Installing yq4 done:"
  which yq4
}
export -f install_yq4

function install_butane() {
  log "Checking/installing butane..."
  if ! [ -x "\$(command -v butane)" ]; then
    wget -q -O /tmp/butane "https://github.com/coreos/butane/releases/download/v0.18.0/butane-x86_64-unknown-linux-gnu"
    chmod u+x /tmp/butane
  fi
  log "Installing butane done:"
  which butane
}
export -f install_butane

EOF
