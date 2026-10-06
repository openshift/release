#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
# shellcheck disable=SC2154
trap 'rc=$?; if [[ "${rc}" -ne 0 ]]; then echo "ERROR: Step failed at line ${LINENO} with exit code ${rc}"; fi' EXIT

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
SEED_VM_NAME=$(cat ${SHARED_DIR}/seed_vm_name)
seed_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${SEED_VM_NAME}/auth/kubeconfig

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

readonly MAX_RETRY_ATTEMPTS=3
readonly INITIAL_RETRY_DELAY=10

# Generic retry function to handle transient network failures
retry() {
  local max_attempts="${1}"
  local initial_delay="${2}"
  shift 2

  local attempt=1
  local delay="${initial_delay}"

  until "$@"; do
    local exit_code=$?
    if [[ ${attempt} -ge ${max_attempts} ]]; then
      echo "ERROR: Command failed after ${max_attempts} attempts (exit code: ${exit_code})"
      return "${exit_code}"
    fi

    echo "Attempt ${attempt}/${max_attempts} failed (exit code: ${exit_code}), retrying in ${delay}s..."
    sleep "${delay}"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done

  return 0
}

cat <<EOF > ${SHARED_DIR}/gather_seed_lca.sh
#!/bin/bash
set -xeuo pipefail

# Setup directories for data
cd ${remote_workdir}
gather_dir=./must-gather-lca-${SEED_VM_NAME}

export KUBECONFIG=${seed_kubeconfig}

oc adm must-gather --image=${LCA_PULL_REF} --dest-dir=\$gather_dir

echo "compressing must gather contents..."
sudo tar cvaf must-gather-lca-${SEED_VM_NAME}.tar.gz \$gather_dir
EOF

chmod +x ${SHARED_DIR}/gather_seed_lca.sh

echo "Transferring gather LCA script..."
retry "${MAX_RETRY_ATTEMPTS}" "${INITIAL_RETRY_DELAY}" scp "${SSHOPTS[@]}" ${SHARED_DIR}/gather_seed_lca.sh $ssh_host_ip:$remote_workdir

echo "Gather seed LCA..."
retry "${MAX_RETRY_ATTEMPTS}" "${INITIAL_RETRY_DELAY}" ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/gather_seed_lca.sh"

echo "Pulling must gather data from the host..."
retry "${MAX_RETRY_ATTEMPTS}" "${INITIAL_RETRY_DELAY}" scp "${SSHOPTS[@]}" $ssh_host_ip:$remote_workdir/must-gather-lca-${SEED_VM_NAME}.tar.gz ${ARTIFACT_DIR}

