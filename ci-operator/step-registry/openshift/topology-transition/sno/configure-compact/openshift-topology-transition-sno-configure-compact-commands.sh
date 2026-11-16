#!/bin/bash
set -euo pipefail

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

# Compact-cluster scheduling policy belongs to this workflow, not add-nodes.
oc patch scheduler cluster --type=merge -p '{"spec":{"mastersSchedulable":true}}'
oc label nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/worker= --overwrite
oc adm uncordon -l node-role.kubernetes.io/master

REMOTE
