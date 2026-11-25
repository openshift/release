#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [ "${ENABLE_CAPI:-false}" != "true" ]; then
  echo "CAPI feature is not enabled. Skipping..."
  exit 0
fi

if [ -z "${ADDITIONAL_WORKERS}" ] || [ "${ADDITIONAL_WORKERS_DAY2}" != "true" ]; then
  echo "Missing number of ADDITIONAL_WORKERS or ADDITIONAL_WORKERS_DAY2 is not set to true. Exiting..."
  exit 1
fi

architecture="${architecture:-amd64}"

# Check for mixed architecture scenarios
case "${architecture}" in
  "amd64")
    if  [ -n "${ADDITIONAL_WORKER_ARCHITECTURE:-}" ] && [ "${ADDITIONAL_WORKER_ARCHITECTURE}" != "x86_64" ]; then
        echo "Error: Mixed architecture cluster (${architecture} with ${ADDITIONAL_WORKER_ARCHITECTURE} worker) is not supported. Exiting."
        exit 1
    fi
    ;;
  "arm64")
    if [ -n "${ADDITIONAL_WORKER_ARCHITECTURE:-}" ] && [ "${ADDITIONAL_WORKER_ARCHITECTURE}" != "aarch64" ]; then
        echo "Error: Mixed architecture cluster (${architecture} with ${ADDITIONAL_WORKER_ARCHITECTURE} worker) is not supported. Exiting."
        exit 1
    fi
    ;;
esac

capi_namespace="openshift-cluster-api"
DIR=/tmp/CAPI
mkdir -p "${DIR}"
bmhlist=()

# Detect OpenShift version to determine which CAPI API version to use
ocp_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d. -f1,2)
ocp_major=$(echo "${ocp_version}" | cut -d. -f1)
ocp_minor=$(echo "${ocp_version}" | cut -d. -f2)

echo -e "\n[INFO] Detected OpenShift version: ${ocp_version}"

echo -e "\n[INFO] Waiting for CAPI operator to be ready..."
# Wait for capm3-controller-manager deployment to be ready
timeout=300
elapsed=0
while ! oc get deployment capm3-controller-manager -n "${capi_namespace}" 2>/dev/null | grep -q "1/1"; do
  if [ $elapsed -ge $timeout ]; then
    echo "ERROR: Timeout waiting for capm3-controller-manager deployment"
    oc get deployment capm3-controller-manager -n "${capi_namespace}" 2>&1 || true
    exit 1
  fi
  echo "Waiting for capm3-controller-manager deployment... (${elapsed}s/${timeout}s)"
  sleep 10
  elapsed=$((elapsed + 10))
done
echo "[INFO] CAPI is ready"

echo -e "\n[INFO] Waiting for ${capi_namespace} namespace to be created..."
timeout=300
elapsed=0
while ! oc get namespace "${capi_namespace}" 2>/dev/null; do
  if [ $elapsed -ge $timeout ]; then
    echo "ERROR: Timeout waiting for ${capi_namespace} namespace"
    exit 1
  fi
  echo "Waiting for ${capi_namespace} namespace to be created... (${elapsed}s/${timeout}s)"
  sleep 10
  elapsed=$((elapsed + 10))
done
echo "[INFO] ${capi_namespace} namespace is ready"

if [[ "${ocp_major}" -gt 4 ]] || [[ "${ocp_major}" -eq 4 && "${ocp_minor}" -gt 21 ]] ; then
 capi_api_version="v1beta2"
 infra_api='apiGroup: infrastructure.cluster.x-k8s.io'
else
  capi_api_version="v1beta1"
  infra_api='apiVersion: infrastructure.cluster.x-k8s.io/v1beta1'
fi
echo -e "\n[INFO] Using CAPI API version: ${capi_api_version}"

echo -e "\n[INFO] Preparing the baremetalhost resource file to add with CAPI..."
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
  namespace: "${capi_namespace}"
type: Opaque
data:
  username: $(echo -n "${bmc_user}" | base64)
  password: $(echo -n "${bmc_pass}" | base64)
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: "${name}"
  namespace: "${capi_namespace}"
spec:
  online: true
  bootMACAddress: "${provisioning_mac}"
  bmc:
    address: "${redfish_scheme}://${bmc_address}${redfish_base_uri}"
    credentialsName: "${name}-bmc-secret"
    disableCertificateVerification: true
  rootDeviceHints:
    deviceName: "${root_device}"
EOF
  fi
done

oc get secret worker-user-data-managed -n openshift-machine-api -o yaml | sed "s/namespace: .*/namespace: ${capi_namespace}/" | oc apply -f -
oc apply -f "${DIR}/"

replicas=${#bmhlist[@]}
infra_name=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
machinetemplate="machinetemplate"
machineset="capiset"

function check_state() {
  local state=$1
  local interval=$2

  while ! oc get baremetalhost "${bmhname}" -n "${capi_namespace}" -o=jsonpath='{.status.provisioning.state}{"\n"}' | grep "${state}"; do
    echo "Baremetalhost ${bmhname} is not ${state}. Waiting ${interval} seconds..."
    sleep "${interval}"
  done
}

echo -e "\n[INFO] Waiting for CAPI baremetalhosts to be available for 8 minutes
before probing every 30 seconds"
sleep 480
for bmhname in "${bmhlist[@]}"; do
  check_state available 30 &
done
wait
echo -e "\n[INFO] CAPI baremetalhosts are available"

# Create Machine template Resource"
cat > "${DIR}/Metal3MachineTemplate.yaml" <<EOF
apiVersion: infrastructure.cluster.x-k8s.io/${capi_api_version}
kind: Metal3MachineTemplate
metadata:
  name: "${machinetemplate}"
  namespace: "${capi_namespace}"
spec:
  template:
    spec:
      customDeploy:
        method: "install_coreos"
      userData:
        name: "worker-user-data-managed"
EOF

# Create Machine Set Resource"
cat > "${DIR}/Metal3MachineSet.yaml" <<EOF
apiVersion: cluster.x-k8s.io/${capi_api_version}
kind: MachineSet
metadata:
  name: "${machineset}"
  namespace: "${capi_namespace}"
  labels:
    cluster.x-k8s.io/cluster-name: "${infra_name}"
spec:
  clusterName: "${infra_name}"
  replicas: 1
  selector:
    matchLabels:
      test: example
      cluster.x-k8s.io/cluster-name: "${infra_name}"
      cluster.x-k8s.io/set-name: "${machineset}"
  template:
    metadata:
      labels:
        test: example
        cluster.x-k8s.io/cluster-name: "${infra_name}"
        cluster.x-k8s.io/set-name: "${machineset}"
    spec:
      bootstrap:
       dataSecretName: worker-user-data-managed
      clusterName: "${infra_name}"
      infrastructureRef:
        ${infra_api}
        kind: Metal3MachineTemplate
        name: "${machinetemplate}"
EOF

echo -e "\n[INFO] List all resource files"
cat "${DIR}"/*.yaml | sed 's/pass.*$/pass ** HIDDEN **/g'

oc create -f "${DIR}/Metal3MachineTemplate.yaml"
oc create -f "${DIR}/Metal3MachineSet.yaml"

echo -e "\n[INFO] Wait 30 seconds for ${capi_namespace} machineset to start"
sleep 30

while ! oc get baremetalhost -n "${capi_namespace}" | grep "provisioning"; do
  oc get baremetalhost -n "${capi_namespace}"
  echo "Baremetalhost provisioning has not started. Waiting 10 seconds..."
  sleep 10
done

if [ "${replicas}" -gt 1 ]; then
  echo -e "\n[INFO] Scale ${replicas} replicas"
  oc scale machineset.cluster.x-k8s.io "${machineset}" -n "${capi_namespace}" --replicas="${replicas}"
fi

echo -e "\n[INFO] Waiting 25 mins before probing for provisioned state"
sleep 1500

echo -e "\n[INFO] Probing for CAPI baremetalhosts to be provisioned"
for bmhname in "${bmhlist[@]}"; do
  check_state provisioned 30 &
done
wait

echo -e "\n[INFO] Probing for nodes joining the cluster and becoming ready"

function wait_for_node_ready() {
  local bmhname=$1

  # Wait for node to join the cluster
  while ! oc get nodes -o name | grep -q "${bmhname}"; do
    echo "${bmhname} has not joined the cluster. Waiting 30 seconds..."
    sleep 30
  done

  # Get the actual node name from BMH status
  local bmhnode
  bmhnode=$(oc get baremetalhost "${bmhname}" -n "${capi_namespace}" -o jsonpath='{.status.hardware.hostname}')

  # Wait for node to be ready
  while ! oc get nodes "${bmhnode}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; do
    echo "Node ${bmhname} is not Ready. Waiting for 30 seconds..."
    sleep 30
  done

  echo "[INFO] Node ${bmhname} is Ready"
}

# Check all nodes in parallel
for bmhname in "${bmhlist[@]}"; do
  wait_for_node_ready "${bmhname}" &
done
wait

echo "[INFO] All CAPI worker nodes are ready"
