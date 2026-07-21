#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# After IPI terraform brings up masters (WORKER_REPLICAS=0), create workers the UPI way
# (virt-install + ignition disk) so s390x avoids machine-api/libvirt ACPI domain XML.

# libvirt-installer image sets PATH=/bin; oc/virsh helpers live under /usr/bin.
export PATH="/usr/bin:/bin:${PATH:-}"

if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "Missing ${SHARED_DIR}/kubeconfig; IPI install must succeed before this step"
  exit 1
fi
if [[ ! -f "${SHARED_DIR}/metadata.json" ]]; then
  echo "Missing ${SHARED_DIR}/metadata.json; need infraID for base volume and network name"
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc not found in PATH=${PATH}"
  exit 1
fi

# mikefarah/yq v4: "yq-v4" uses legacy CLI ("yq-v4 -o=y ..."). Images that only ship "yq"
# require the v4 syntax: "yq eval -o=y ..." (plain "yq -o=y" treats the expression as a subcommand).
# ocp/4.15:libvirt-installer has yq-v4 but not jq — never fall back to bare "yq eval" when yq-v4 exists.
if ! command -v yq-v4 >/dev/null 2>&1 && ! command -v yq >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
  echo "Neither yq-v4, yq, nor jq found in PATH"
  exit 1
fi

leaseLookup() {
  local lookup
  local leases="${CLUSTER_PROFILE_DIR}/leases"
  if command -v yq-v4 >/dev/null 2>&1; then
    lookup=$(yq-v4 -oy ".[\"${LEASED_RESOURCE}\"].${1}" "${leases}")
  else
    lookup=$(yq eval -o=y ".[\"${LEASED_RESOURCE}\"].${1}" "${leases}")
  fi
  if [[ -z "${lookup}" || "${lookup}" == "null" ]]; then
    echo "Couldn't find ${1} in lease config"
    exit 1
  fi
  echo "${lookup}"
}

HOSTNAME="$(leaseLookup 'hostname')"
# Prefer workflow LIBVIRT_POOL_NAME (same pool as IPI install) over step POOL_NAME default.
POOL_NAME="${LIBVIRT_POOL_NAME:-${POOL_NAME:-multiarch-ci-pool}}"
COMPUTE_COUNT="${COMPUTE_COUNT:-2}"
# IPI jobs already set WORKER_MEMORY; prefer that over DOMAIN_MEMORY default.
DOMAIN_MEMORY="${WORKER_MEMORY:-${DOMAIN_MEMORY:-16384}}"
DOMAIN_VCPUS="${DOMAIN_VCPUS:-6}"
VIRT_INSTALL_OSINFO="${VIRT_INSTALL_OSINFO:-rhel9-unknown}"

if command -v jq >/dev/null 2>&1; then
  INFRA_ID=$(jq -r '.infraID // empty' "${SHARED_DIR}/metadata.json")
elif command -v yq-v4 >/dev/null 2>&1; then
  INFRA_ID=$(yq-v4 -oy '.infraID // ""' "${SHARED_DIR}/metadata.json")
else
  INFRA_ID=$(yq eval -o=y '.infraID // ""' "${SHARED_DIR}/metadata.json")
fi
if [[ -z "${INFRA_ID}" || "${INFRA_ID}" == "null" ]]; then
  echo "Could not determine infraID from metadata.json"
  exit 1
fi

# IPI terraform names the libvirt network after infraID (cluster_id).
NETWORK_NAME="${INFRA_ID}"
BASE_VOLUME="${INFRA_ID}-base"
IGNITION_VOLUME="${LEASED_RESOURCE}-worker-ignition-volume"

LIBVIRT_CONNECTION="qemu+tcp://${HOSTNAME}/system"
VIRSH="mock-nss.sh virsh --connect ${LIBVIRT_CONNECTION}"

echo "Creating ${COMPUTE_COUNT} virsh workers on ${HOSTNAME}"
echo "  pool=${POOL_NAME} network=${NETWORK_NAME} base_volume=${BASE_VOLUME}"
echo "  memory=${DOMAIN_MEMORY}MiB vcpus=${DOMAIN_VCPUS}"

if ! ${VIRSH} pool-list --name | grep -qx "${POOL_NAME}"; then
  echo "ERROR: storage pool ${POOL_NAME} is not active"
  ${VIRSH} pool-list --all
  exit 1
fi
if ! ${VIRSH} vol-list --pool "${POOL_NAME}" | awk '{print $1}' | grep -qx "${BASE_VOLUME}"; then
  echo "ERROR: RHCOS base volume ${BASE_VOLUME} not found in pool ${POOL_NAME}"
  ${VIRSH} vol-list --pool "${POOL_NAME}"
  exit 1
fi
if ! ${VIRSH} net-list --name | grep -qx "${NETWORK_NAME}"; then
  echo "ERROR: libvirt network ${NETWORK_NAME} not found (IPI terraform network)"
  ${VIRSH} net-list --all
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

# Prefer ignition saved by the install step; otherwise pull live worker userdata from the cluster.
echo "Extracting worker ignition..."
WORKER_IGN="${WORKDIR}/worker.ign"
if [[ -s "${SHARED_DIR}/worker.ign" ]]; then
  echo "Using ${SHARED_DIR}/worker.ign from install step"
  cp "${SHARED_DIR}/worker.ign" "${WORKER_IGN}"
else
  set +e
  for secret in worker-user-data worker-user-data-managed; do
    echo "Trying secret/${secret} in openshift-machine-api..."
    if oc -n openshift-machine-api extract "secret/${secret}" --keys=userData --to=- > "${WORKER_IGN}" 2>"${WORKDIR}/extract.err"; then
      if [[ -s "${WORKER_IGN}" ]]; then
        echo "Extracted worker ignition from secret/${secret}"
        break
      fi
    fi
    cat "${WORKDIR}/extract.err" >&2 || true
  done
  set -e
fi
if [[ ! -s "${WORKER_IGN}" ]]; then
  echo "ERROR: could not extract worker ignition (SHARED_DIR/worker.ign or worker-user-data(-managed))"
  oc -n openshift-machine-api get secrets 2>&1 | head -50 || true
  exit 1
fi

echo "Uploading worker ignition volume ${IGNITION_VOLUME}..."
${VIRSH} vol-delete --pool "${POOL_NAME}" "${IGNITION_VOLUME}" || true
${VIRSH} vol-create-as \
  --name "${IGNITION_VOLUME}" \
  --pool "${POOL_NAME}" \
  --format raw \
  --capacity "$(wc -c < "${WORKER_IGN}")"
${VIRSH} vol-upload \
  --vol "${IGNITION_VOLUME}" \
  --pool "${POOL_NAME}" \
  --file "${WORKER_IGN}"

clone_volume() {
  local newname=$1
  ${VIRSH} vol-delete --pool "${POOL_NAME}" "${newname}" || true
  ${VIRSH} vol-clone \
    --pool "${POOL_NAME}" \
    --vol "${BASE_VOLUME}" \
    --newname "${newname}"
}

create_worker() {
  local name=$1
  local mac=$2
  echo "Creating worker ${name} (mac=${mac})..."
  clone_volume "${name}-volume"
  # mock-nss.sh wraps virsh; virt-install needs the qemu+tcp URI via --connect.
  mock-nss.sh virt-install \
    --connect "${LIBVIRT_CONNECTION}" \
    --name "${name}" \
    --memory "${DOMAIN_MEMORY}" \
    --vcpus "${DOMAIN_VCPUS}" \
    --network "network=${NETWORK_NAME},mac=${mac}" \
    --disk="vol=${POOL_NAME}/${name}-volume" \
    --osinfo "${VIRT_INSTALL_OSINFO}" \
    --graphics=none \
    --import \
    --noautoconsole \
    --disk "vol=${POOL_NAME}/${IGNITION_VOLUME},format=raw,readonly=on,serial=ignition,startup_policy=optional"
}

for ((i = 0; i < COMPUTE_COUNT; i++)); do
  NODE="${LEASED_RESOURCE}-compute-${i}"
  MAC_ADDRESS=$(leaseLookup "compute[$i].mac")
  # Remove leftovers from prior failed runs
  ${VIRSH} destroy "${NODE}" || true
  ${VIRSH} undefine "${NODE}" || true
  create_worker "${NODE}" "${MAC_ADDRESS}"
done

# Keep worker MachineSet at 0 so machine-api does not also try to spawn ACPI-broken domains.
if oc get machineset -n openshift-machine-api -o name 2>/dev/null | grep -q worker; then
  echo "Ensuring worker MachineSets stay scaled to 0..."
  oc get machineset -n openshift-machine-api -o name | grep worker | xargs -r oc scale -n openshift-machine-api --replicas=0 || true
fi

echo "Approving CSRs until workers are Ready..."
approve_done="${WORKDIR}/approve-done"
rm -f "${approve_done}"
(
  set +e
  while [[ ! -f "${approve_done}" ]]; do
    if command -v jq >/dev/null 2>&1; then
      oc get csr -ojson 2>/dev/null \
        | jq -r '.items[] | select((.status.conditions // []) | length == 0) | .metadata.name' \
        | xargs --no-run-if-empty oc adm certificate approve || true
    elif command -v yq-v4 >/dev/null 2>&1; then
      oc get csr -ojson 2>/dev/null \
        | yq-v4 -oy '.items[] | select(.status | length == 0) | .metadata.name' \
        | xargs --no-run-if-empty oc adm certificate approve || true
    else
      oc get csr --no-headers 2>/dev/null | awk '/Pending/ {print $1}' \
        | xargs --no-run-if-empty oc adm certificate approve || true
    fi
    sleep 15
  done
) &
APPROVE_PID=$!

deadline=$((SECONDS + 45 * 60))
while true; do
  ready=$(oc get nodes --no-headers 2>/dev/null | awk '$3 !~ /master/ && $2 == "Ready" {c++} END{print c+0}')
  echo "Ready worker nodes: ${ready}/${COMPUTE_COUNT}"
  if [[ "${ready}" -ge "${COMPUTE_COUNT}" ]]; then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "ERROR: timed out waiting for ${COMPUTE_COUNT} Ready workers"
    oc get nodes -o wide || true
    oc get csr || true
    touch "${approve_done}"
    wait "${APPROVE_PID}" || true
    exit 1
  fi
  sleep 30
done

touch "${approve_done}"
wait "${APPROVE_PID}" || true

echo "Virsh workers are Ready."
oc get nodes -o wide
