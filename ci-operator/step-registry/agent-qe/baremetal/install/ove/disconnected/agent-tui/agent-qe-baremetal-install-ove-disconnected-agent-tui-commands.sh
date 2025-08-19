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
pids=()
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  CURRENT_RENDEZVOUS_NODE="$RENDEZVOUS_NODE"
  if [ "$CURRENT_RENDEZVOUS_NODE" = "yes" ]; then
    RENDEZVOUS_IP=$(echo "$bmhost" | jq -r '.ip')
    echo "${RENDEZVOUS_IP}" >"${SHARED_DIR}"/node-zero-ip.txt
    RENDEZVOUS_NODE="no"
  fi
  IPMITOOL_IP=$(echo "$bmhost" | jq -r '.bmc_address')
  IPMITOOL_USERNAME=$(echo "$bmhost" | jq -r '.bmc_user')
  IPMITOOL_PASSWORD=$(echo "$bmhost" | jq -r '.bmc_pass')
  HOST_MACHINE=$(echo "$bmhost" | jq -r '.host')
  (
    echo "Agent TUI execution started for $HOST_MACHINE"
    IPMITOOL_IP="$IPMITOOL_IP" \
    IPMITOOL_USERNAME="$IPMITOOL_USERNAME" \
    IPMITOOL_PASSWORD="$IPMITOOL_PASSWORD" \
    RENDEZVOUS_IP="$RENDEZVOUS_IP" \
    RENDEZVOUS_NODE="$CURRENT_RENDEZVOUS_NODE" \
    python3.11 agent-tui/run_agent_tui.py || {
      echo "Agent TUI settings failed for $HOST_MACHINE."
      exit 1
    }
  ) &
  pids+=($!)
  sleep 2s
done

for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    cp -r /tmp/agent_logs/* "$ARTIFACT_DIR"
    exit 1
  fi
done
echo "Agent TUI execution completed successfully!"