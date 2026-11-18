#!/bin/bash
set -euo pipefail

gather_skipped=false

finish_step() {
  local result=$?

  trap - EXIT
  if (( result != 0 )); then
    printf 'Gather step: failed (exit %s)\n' "${result}" >&2
  elif [[ "${gather_skipped}" == true ]]; then
    echo 'Gather step: skipped (no EC2 host handoff)'
  else
    echo 'Gather step: completed successfully'
  fi

  exit "${result}"
}
trap finish_step EXIT

echo 'Gather step: starting'

# The host may not exist if EC2 allocation failed. Cleanup still runs next.
if [[ ! -s "${SHARED_DIR}/remote_workdir" || ! -s "${SHARED_DIR}/public_address" ]]; then
  gather_skipped=true
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
mkdir -p results/host results/cluster || exit 1
warnings=0

warn() {
  warnings=$((warnings + 1))
  printf 'Gather warning: %s\n' "$1" >&2
}

export PATH="${PWD}/bin:${PATH}"
export KUBECONFIG="${PWD}/install/auth/kubeconfig"

echo 'Collecting VM and host status'

# Copy only known public files. Install assets and Ignition contain credentials.
cp inventory.json state.json results/host/ 2>/dev/null || warn 'some host state files are unavailable'
virsh list --all > results/host/vms.txt 2>/dev/null || warn 'could not list VMs'
network=$(jq -er '.network // "transitionbm"' state.json 2>/dev/null) || network=transitionbm
virsh net-dumpxml "${network}" > results/host/network.xml 2>/dev/null || warn 'could not collect VM network state'
journalctl --no-pager -u libvirtd -u virtqemud -u virtnetworkd -u haproxy > results/host/services.log 2>/dev/null || warn 'could not collect host service logs'
cp /var/log/libvirt/qemu/*.log results/host/ 2>/dev/null || warn 'VM logs are unavailable'
echo 'Collecting the redacted installer log'
if [[ -s install/.openshift_install.log ]]; then
  # Redact before writing artifacts; keep the surrounding log text intact.
  sed -E 's/(password: (\\?")?)[^"\\[:space:]]+/\1REDACTED/g' \
    install/.openshift_install.log > results/cluster/install.log || warn 'could not collect the installer log'
else
  echo 'Installer log is not available yet'
fi
if [[ -s "${KUBECONFIG}" ]]; then
  echo 'Collecting cluster state (up to 2 minutes per request)'
  timeout 2m oc get nodes,clusteroperators -o yaml > results/cluster/status.yaml 2>&1 || warn 'could not collect node and operator state'
  timeout 2m oc get infrastructure cluster -o yaml > results/cluster/infrastructure.yaml 2>&1 || warn 'could not collect infrastructure state'
  timeout 2m oc get events -A -o yaml > results/cluster/events.yaml 2>&1 || warn 'could not collect cluster events'
  echo 'Starting must-gather (20 minute limit)'
  timeout --kill-after=1m 20m oc adm must-gather --dest-dir=results/cluster/must-gather \
    > results/cluster/must-gather.log 2>&1 || warn 'must-gather did not complete successfully'
else
  echo 'Skipping cluster collection: no kubeconfig is available'
fi
printf 'Host and cluster collection finished with %s warnings\n' "${warnings}"
chown -R ec2-user:ec2-user results
REMOTE

echo 'Copying collected files to CI artifacts'
mkdir -p "${ARTIFACT_DIR}"
scp "${SSHOPTS[@]}" -r "${remote}:${workdir}/results/." "${ARTIFACT_DIR}/"
