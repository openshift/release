#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [[ ! "${JOB_NAME}" =~ "multi-arch" ]]; then
  echo "Not a multi-arch job. Skipping..."
  exit 0
fi

if [ "${ADDITIONAL_WORKERS_DAY2:-false}" != "true" ]; then
  echo "No day 2 additional workers to add. Skipping..."
  exit 0
fi

if [ -z "${ADDITIONAL_WORKERS}" ] || [ -z "${ADDITIONAL_WORKER_ARCHITECTURE}" ]; then
  echo "Number of ADDITIONAL_WORKERS or ADDITIONAL_WORKER_ARCHITECTURE is not set. Exiting..."
  exit 1
fi

architecture="${architecture:-amd64}"
additional_worker_arch=$(echo "${ADDITIONAL_WORKER_ARCHITECTURE}" | sed 's/aarch64/arm64/;s/x86_64/amd64/')

# Check for mixed architecture scenarios
case "${architecture}" in
  "amd64")
    if [ "${additional_worker_arch}" != "arm64" ]; then
        echo "Error: An 'arm64' additional worker is expected for a multi-arch ${architecture} \
        cluster. Worker architecture given is ${additional_worker_arch}. Exiting."
        exit 1
    fi
    ;;
  "arm64")
    echo "Error: Multi-arch is not supported with ${architecture} control planes. Exiting."
    exit 1
    ;;
esac

bm_namespace="openshift-machine-api"
DIR=/tmp/multi-arch
mkdir -p "${DIR}"
bmhlist=()

check_prov_vmedia() {
  oc get bmh -n "${bm_namespace}" -o jsonpath='{.items[0].spec.bmc.address}' | grep -qi "virtual"
}

echo "[INFO] Preparing the baremetalhost resource file to add multi-arch worker node..."
check_prov_vmedia && vmedia_cluster="true" || vmedia_cluster="false"
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "${bmhost}" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]]; then
    echo "Prepare yaml files for ${name}"
    bmhlist+=("${name}")
    if ${vmedia_cluster}; then
      prov_address="${redfish_scheme}://${bmc_address}${redfish_base_uri}"
      username=$(echo -n "${redfish_user}" | base64)
      password=$(echo -n "${redfish_password}" | base64)
    elif [[ "${ADDITIONAL_WORKERS_VENDOR:-}" == "ampere" ]] || [[ "${name}" == *-a-01* ]]; then
      prov_address="${bmc_scheme}://${bmc_address}${bmc_base_uri}"
      username=$(echo -n "${bmc_user}" | base64)
      password=$(echo -n "${bmc_pass}" | base64)
    else
      prov_address="redfish+https://${bmc_address}${redfish_base_uri}"
      username=$(echo -n "${redfish_user}" | base64)
      password=$(echo -n "${redfish_password}" | base64)
    fi

    cat > "${DIR}/${name}.yaml" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: "${name}-bmc-secret"
  namespace: "${bm_namespace}"
type: Opaque
data:
  username: ${username}
  password: ${password}
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: "${name}"
  namespace: "${bm_namespace}"
spec:
  online: true
  bootMACAddress: "${provisioning_mac}"
  architecture: "${arch}"
  bmc:
    address: "${prov_address}"
    credentialsName: "${name}-bmc-secret"
    disableCertificateVerification: true
  rootDeviceHints:
    deviceName: "${root_device}"
EOF
  fi
done

# Add the additional worker nodes
echo "[INFO] Adding the worker nodes"
find "${DIR}" -name "*.yaml" -exec oc apply -f {} \;

additional_replicas=${#bmhlist[@]}

# Wait helper function with timeout
wait_with_timeout() {
  local timeout=$1
  local condition=$2
  local message=$3
  local interval=${4:-30}
  local elapsed=0

  while ! eval "${condition}"; do
    if [ ${elapsed} -ge ${timeout} ]; then
      echo "ERROR: Timeout after ${timeout} seconds waiting for: ${message}"
      return 1
    fi
    echo "${message} (elapsed: ${elapsed}s/${timeout}s)"
    sleep ${interval}
    elapsed=$((elapsed + interval))
  done
  return 0
}

echo "[INFO] Waiting for additional worker baremetalhosts to be available"
for bmhname in "${bmhlist[@]}"; do
  wait_with_timeout 1800 \
    "oc get baremetalhost '${bmhname}' -n '${bm_namespace}' -o=jsonpath='{.status.provisioning.state}' | grep -q available" \
    "Baremetalhost ${bmhname} is not available yet" \
    60 || exit 1
done
echo "[INFO] Additional baremetalhosts are available"

echo "[INFO] List all resource files"
more "${DIR}"/*.yaml |& sed 's/pass.*$/pass ** HIDDEN **/g'

machineset=$(oc get machineset -n "${bm_namespace}" -o jsonpath='{.items[0].metadata.name}{"\n"}')
current_replicas=$(oc get machineset -n "${bm_namespace}" -o jsonpath='{.items[0].spec.replicas}{"\n"}')
replicas=$(( current_replicas + additional_replicas ))

# Scale to total replicas
echo "[INFO] Scaling machineset to ${replicas} replicas"
oc scale machineset "${machineset}" -n "${bm_namespace}" --replicas="${replicas}"

echo "[INFO] Waiting for additional baremetalhosts to be provisioned"
for bmhname in "${bmhlist[@]}"; do
  wait_with_timeout 2400 \
    "oc get baremetalhost '${bmhname}' -n '${bm_namespace}' -o=jsonpath='{.status.provisioning.state}' | grep -q provisioned" \
    "Baremetalhost ${bmhname} is not provisioned yet" \
    60 || exit 1
done

echo "[INFO] Waiting for available replicas in machineset"
wait_with_timeout 1200 \
  "oc get machineset -n '${bm_namespace}' -o jsonpath='{.items[0].status.availableReplicas}' | grep -q '${replicas}'" \
  "${replicas} replicas are not available in ${machineset} yet" \
  30 || exit 1

echo "[INFO] Waiting for ready replicas in machineset"
wait_with_timeout 300 \
  "oc get machineset -n '${bm_namespace}' -o jsonpath='{.items[0].status.readyReplicas}' | grep -q '${replicas}'" \
  "${replicas} replicas are not ready in ${machineset} yet" \
  30 || exit 1

echo "[INFO] Additional worker nodes added successfully, checking nodes are Ready"
for bmhname in "${bmhlist[@]}"; do
  bmhnode=$(oc get nodes -o name | grep "${bmhname}" | awk -F/ '{print $2}')
  if [ -z "${bmhnode}" ]; then
    echo "ERROR: Could not find node matching ${bmhname}"
    exit 1
  fi
  wait_with_timeout 300 \
    "oc get nodes '${bmhnode}' -o=jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q 'True'" \
    "Node ${bmhnode} is not Ready yet" \
    5 || exit 1
done

echo "[INFO] Adding multi-arch worker step completed"
