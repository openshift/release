#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

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
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "${bmhost}" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]]; then
    echo "Prepare yaml files for ${name}"
    bmhlist+=("${name}")
    if check_prov_vmedia; then
      prov_address="${redfish_scheme}://${bmc_address}${redfish_base_uri}"
    else
      prov_address="${bmc_scheme}://${bmc_address}${bmc_base_uri}"
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
  username: $(echo -n "${bmc_user}" | base64)
  password: $(echo -n "${bmc_pass}" | base64)
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
echo "--- Adding the worker nodes ---"
oc apply -f "${DIR}/*.yaml"

additional_replicas=${#bmhlist[@]}

echo "--- Waiting for addtional worker baremetalhosts to be available ---"
sleep 480
for bmhname in "${bmhlist[@]}"; do
  while ! oc get baremetalhost "${bmhname}" -n "${bm_namespace}" -o=jsonpath='{.status.provisioning.state}{"\n"}' | grep available; do
    echo "Baremetalhost ${bmhname} is not available. Waiting 30 seconds..."
    sleep 30
  done
done
echo "--- Additional baremetalhosts are available ---"

echo "--- List all resource files ---"
more "${DIR}"/*.yaml |& sed 's/pass.*$/pass ** HIDDEN **/g'

machineset=$(oc get machineset -n "${bm_namespace}" -o jsonpath='{.items[0].metadata.name}{"\n"}')
current_replicas=$(oc get machineset -n "${bm_namespace}" -o jsonpath='{.items[0].spec.replicas}{"\n"}')
replicas=$(( current_replicas + additional_replicas ))

# Scale to total replicas
echo "--- Scaling machineset to ${replicas} replicas ---"
oc scale machineset "${machineset}" -n "${bm_namespace}" --replicas="${replicas}"

echo "--- Waiting for additional baremetalhosts to be provisioned ---"
for bmhname in "${bmhlist[@]}"; do
  while ! oc get baremetalhost "${bmhname}" -n "${bm_namespace}" -o=jsonpath='{.status.provisioning.state}{"\n"}' | grep provisioned; do
    echo "Baremetalhost ${bmhname} is not provisioned. Waiting 60 seconds..."
    sleep 60
  done
done

echo "--- Waiting for available replicas in machineset ---"
while ! oc get machineset -n "${bm_namespace}" -o jsonpath='{.items[0].status.availableReplicas}{"\n"}' | grep "${replicas}"; do
  echo "${replicas} replicas are not available in ${machineset}. Waiting 30 seconds..."
    sleep 30
done

echo "--- Waiting for ready replicas in machineset ---"
while ! oc get machineset -n "${bm_namespace}" -o jsonpath='{.items[0].status.readyReplicas}{"\n"}' | grep "${replicas}"; do
  echo "${replicas} replicas are not available in ${machineset}. Waiting 30 seconds..."
    sleep 30
done

echo "--- Additional worker nodes added successfully, checking nodes are Ready ---"
for bmhname in "${bmhlist[@]}"; do
  bmhnode=$(oc get nodes -o name | grep "${bmhname}" | awk -F/ '{print $2}')
  while ! oc get nodes "${bmhnode}" -o=jsonpath='{.status.conditions[3].status}{"\n"}' | grep "True"; do
    echo "Node ${bmhname} is not Ready. Waiting for 5 seconds..."
    sleep 5
  done
done

echo "Adding multi-arch worker step completed"
