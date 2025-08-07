#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ ! -f "${SHARED_DIR}/proxy-conf.sh" ] && { echo "Proxy conf file is not found. Failing."; exit 1; }

if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >>/etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found."
    exit 1
  fi
fi

source "${SHARED_DIR}/proxy-conf.sh"

RENDEZVOUS_NODE="yes"
SSH_PRIVATE_KEY=$(<"${CLUSTER_PROFILE_DIR}"/ssh-privatekey)
export SSH_PRIVATE_KEY

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do

  if [ "$RENDEZVOUS_NODE" = "yes" ]; then
    RENDEZVOUS_IP=$(echo "$bmhost" | jq -r '.ip')
    echo "${RENDEZVOUS_IP}" >"${SHARED_DIR}"/node-zero-ip.txt
    RENDEZVOUS_NODE="no"
  fi
  IPMITOOL_IP=$(echo "$bmhost" | jq -r '.bmc_address')
  IPMITOOL_USERNAME=$(echo "$bmhost" | jq -r '.bmc_user')
  IPMITOOL_PASSWORD=$(echo "$bmhost" | jq -r '.bmc_pass')

  export IPMITOOL_IP
  export IPMITOOL_USERNAME
  export IPMITOOL_PASSWORD
  export RENDEZVOUS_IP
  export RENDEZVOUS_NODE

  echo "Preparing for run.."
  sleep 4m
  if ! python3.11 agent-tui/run_agent_tui.py; then
    echo "Agent TUI settings failed for $IPMITOOL_IP, please check the logs..."
    cp "/tmp/agent_tui.log" "${SHARED_DIR}/"
  fi
done