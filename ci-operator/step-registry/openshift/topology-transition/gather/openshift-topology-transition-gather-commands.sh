#!/bin/bash
set -euo pipefail

# The host may not exist if EC2 allocation failed. Cleanup still runs next.
if [[ ! -s "${SHARED_DIR}/remote_workdir" || ! -s "${SHARED_DIR}/public_address" ]]; then
  exit 0
fi

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
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")
remote="$(cat "${SHARED_DIR}/ssh_user")@$(cat "${SHARED_DIR}/public_address")"
workdir=$(cat "${SHARED_DIR}/remote_workdir")

ssh "${SSHOPTS[@]}" "${remote}" sudo bash -s -- "${workdir}" <<'REMOTE'
set -uo pipefail
cd "$1" || exit 1
mkdir -p results/host results/cluster
export PATH="${PWD}/bin:${PATH}"
export KUBECONFIG="${PWD}/install/auth/kubeconfig"

# Copy only known public files. Install assets and Ignition contain credentials.
cp inventory.json state.json results/host/ 2>/dev/null || true
virsh list --all > results/host/vms.txt
network=$(jq -er '.network // "transitionbm"' state.json 2>/dev/null) || network=transitionbm
virsh net-dumpxml "${network}" > results/host/network.xml
journalctl --no-pager -u libvirtd -u virtqemud -u virtnetworkd -u haproxy > results/host/services.log
cp /var/log/libvirt/qemu/*.log results/host/ 2>/dev/null || true
if [[ -s install/.openshift_install.log ]]; then
  # Redact before writing artifacts; keep the surrounding log text intact.
  sed -E 's/(password: (\\?")?)[^"\\[:space:]]+/\1REDACTED/g' \
    install/.openshift_install.log > results/cluster/install.log
fi
if [[ -s "${KUBECONFIG}" ]]; then
  timeout 2m oc get nodes,clusteroperators -o yaml > results/cluster/status.yaml 2>&1 || true
  timeout 2m oc get infrastructure cluster -o yaml > results/cluster/infrastructure.yaml 2>&1 || true
  timeout 2m oc get events -A -o yaml > results/cluster/events.yaml 2>&1 || true
  timeout --kill-after=1m 20m oc adm must-gather --dest-dir=results/cluster/must-gather \
    > results/cluster/must-gather.log 2>&1 || true
fi
chown -R ec2-user:ec2-user results
REMOTE

scp "${SSHOPTS[@]}" -r "${remote}:${workdir}/results/." "${ARTIFACT_DIR}/"
