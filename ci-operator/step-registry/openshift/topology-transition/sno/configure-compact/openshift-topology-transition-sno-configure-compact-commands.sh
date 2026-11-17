#!/bin/bash
set -euo pipefail

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
trap 'chown -R ec2-user:ec2-user .' EXIT
# shellcheck source=/dev/null
source common.sh

# As in TNT, move API DNS to HAProxy after the new control-plane nodes join.
first_node_ip=$(jq -er '.[0].ip' inventory.json)
first_node_name=$(jq -er '.[0].name' inventory.json)
virsh net-update "${network}" delete dns-host "<host ip='${first_node_ip}'/>" --live --config
virsh net-update "${network}" add-last dns-host \
  "<host ip='${first_node_ip}'><hostname>${first_node_name}</hostname><hostname>${first_node_name}.${cluster_domain}</hostname></host>" --live --config
virsh net-update "${network}" add-last dns-host \
  "<host ip='${gateway}'><hostname>api.${cluster_domain}</hostname><hostname>api-int.${cluster_domain}</hostname></host>" --live --config

# Compact-cluster scheduling policy belongs to this workflow, not add-nodes.
oc patch scheduler cluster --type=merge -p '{"spec":{"mastersSchedulable":true}}'
oc label nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/worker= --overwrite
oc adm uncordon -l node-role.kubernetes.io/master

REMOTE
