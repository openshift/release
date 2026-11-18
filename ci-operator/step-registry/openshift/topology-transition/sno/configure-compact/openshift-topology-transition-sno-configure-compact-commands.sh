#!/bin/bash
set -euo pipefail

finish_step() {
  local result=$?

  trap - EXIT
  if (( result != 0 )); then
    printf 'Configure compact step: failed (exit %s)\n' "${result}" >&2
  else
    echo 'Configure compact step: completed successfully'
  fi

  exit "${result}"
}
trap finish_step EXIT

echo 'Configure compact step: starting'

# SSH requires an entry for the random UID assigned to this container.
if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo '/etc/passwd is not writable, and no user exists for the current UID.' >&2
    exit 1
  fi
fi

SSHOPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")
remote="$(cat "${SHARED_DIR}/ssh_user")@$(cat "${SHARED_DIR}/public_address")"
workdir=$(cat "${SHARED_DIR}/remote_workdir")

ssh "${SSHOPTS[@]}" "${remote}" sudo bash -s -- "${workdir}" <<'REMOTE'
set -euo pipefail
cd "$1"
cleanup_remote() {
  local result=$?

  trap - EXIT
  if ! chown -R ec2-user:ec2-user .; then
    echo 'Could not restore host file ownership' >&2
    if (( result == 0 )); then
      result=1
    fi
  fi

  exit "${result}"
}
trap cleanup_remote EXIT

# shellcheck source=/dev/null
source common.sh

# As in TNT, move API DNS to HAProxy after the new control-plane nodes join.
echo 'Moving API DNS to the load balancer'
set_api_dns "${gateway}"

# Compact-cluster scheduling policy belongs to this workflow, not add-nodes.
echo 'Enabling worker scheduling on control-plane nodes'
oc patch scheduler cluster --type=merge -p '{"spec":{"mastersSchedulable":true}}'
oc label nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/worker= --overwrite >/dev/null
oc adm uncordon -l node-role.kubernetes.io/master >/dev/null

REMOTE
