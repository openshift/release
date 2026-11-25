#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [ "${SCALE_UPI}" != "true" ]; then
  echo "Cluster does not need day 2 worker node. Skipping..."
  exit 0
fi

if [ "${ADDITIONAL_WORKERS_DAY2:-false}" != "true" ]; then
  echo "Day 2 additional workers is set to 'false', it should be set to 'true'. Exiting..."
  exit 1
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
    if [ "${additional_worker_arch}" != "amd64" ]; then
        echo "[Info] ${additional_worker_arch} additional worker to be added to ${architecture} \
        cluster. Lets try!"
    fi
    ;;
  "arm64")
    if [ "${additional_worker_arch}" != "arm64" ]; then
        echo "[Info] ${additional_worker_arch} additional worker to be added to ${architecture} \
        cluster. Lets try!"
    fi
    ;;
esac

bm_namespace="openshift-machine-api"
DIR=/tmp/scale_upi
mkdir -p "${DIR}"
bmhlist=()

check_pods() {
    POD_DATA=$(oc get pods -n "${bm_namespace}" --no-headers 2>/dev/null)
    METAL3_COUNT=$(echo "$POD_DATA" | awk '$1 ~ /^metal3/ && $3 == "Running" {count++} END {print count+0}')
    IRONIC_COUNT=$(echo "$POD_DATA" | awk '$1 ~ /^ironic/ && $3 == "Running" {count++} END {print count+0}')

    echo "Status: Metal3 Running: $METAL3_COUNT/3 | Ironic Running: $IRONIC_COUNT/3"
    if [[ $METAL3_COUNT -ge 3 && $IRONIC_COUNT -ge 3 ]]; then
        return 0
    else
        return 1
    fi
}

function check_state() {
  state="${1}"
  wait_time="${2}"
  echo "--- Waiting for addtional worker baremetalhosts to be in ${state} state ---"
  for bmhname in "${bmhlist[@]}"; do
    while ! oc get baremetalhost "${bmhname}" -n "${bm_namespace}" -o=jsonpath='{.status.provisioning.state}{"\n"}' | grep "${state}"; do
      echo "Baremetalhost ${bmhname} is not ${state}. Waiting ${wait_time} seconds..."
      sleep "${wait_time}"
    done
  done
}

function approve_csrs() {
  while [[ ! -f '/tmp/add-worker-complete' ]]; do
    sleep 30
    echo "approve_csrs() running..."
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
      | xargs --no-run-if-empty oc adm certificate approve || true
  done
}

# Enable Metal platform components on non-baremetal platforms
cat > "${DIR}/provisioning.yaml" <<EOF
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: "Disabled"
  watchAllNamespaces: false
EOF

oc create -f "${DIR}/provisioning.yaml"
sleep 60

# Check ironic and metal3 pods exist after creating provisioning resource
MAX_RETRIES=10
SLEEP_TIME=30
for ((i=1; i<=MAX_RETRIES; i++)); do
    if check_pods; then
      echo "[INFO] Cluster operators/pods are healthy."
      break
    elif [ "${i}" -lt "${MAX_RETRIES}" ]; then
      echo "[INFO] All pods are not running. Retrying in ${SLEEP_TIME}s... ($i/$MAX_RETRIES)"
      sleep $SLEEP_TIME
    elif [ "${i}" -eq "${MAX_RETRIES}" ]; then
      echo "[ERROR] Metal3 or Ironic pods are not running after $MAX_RETRIES attempts."
      exit 1
    fi
done

echo "[INFO] Preparing the baremetalhost resource file to add worker node..."
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "${bmhost}" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]]; then
    echo "Prepare yaml files for ${name}"
    bmhlist+=("${name}")
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
  architecture: ${ADDITIONAL_WORKER_ARCHITECTURE}
  customDeploy:
    method: install_coreos
  bmc:
    address: "${redfish_scheme}://${bmc_address}${redfish_base_uri}"
    credentialsName: "${name}-bmc-secret"
    disableCertificateVerification: true
  rootDeviceHints:
    deviceName: "${root_device}"
  userData:
    name: worker-user-data-managed
    namespace: "${bm_namespace}"
EOF
  fi
done

# Add the additional worker nodes
echo "--- Adding the worker nodes ---"
oc apply -f "${DIR}/*-a-*.yaml"

# Waiting for addtional worker baremetalhosts to be in inspecting state
check_state inspecting 60

echo "--- Waiting for 5 mins ---"
sleep 300

# Waiting for addtional worker baremetalhosts to be in provisioned state
check_state provisioned 60

echo "--- List all resource files ---"
more "${DIR}"/*.yaml |& sed 's/pass.*$/pass ** HIDDEN **/g'

# Approve csrs
approve_csrs &

echo "--- Check worker nodes are added successfully and are Ready ---"
for bmhname in "${bmhlist[@]}"; do
  # Wait for node to appear first
  while true; do
    bmhnode=$(oc get nodes -o name | grep "${bmhname}" | awk -F/ '{print $2}' || true)
    if [ -n "${bmhnode}" ]; then
      echo "Node ${bmhname} found: ${bmhnode}"
      break
    fi
    echo "Node ${bmhname} not found yet. Waiting 10 seconds..."
    sleep 10
  done

  # Wait for node to be Ready
  while ! oc get nodes "${bmhnode}" -o=jsonpath='{.status.conditions[3].status}{"\n"}' | grep -q "True"; do
    echo "Node ${bmhname} is not Ready. Waiting 10 seconds..."
    sleep 10
  done
done

touch /tmp/add-worker-complete
