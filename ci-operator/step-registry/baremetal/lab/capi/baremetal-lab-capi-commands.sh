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
    if [ "${ADDITIONAL_WORKER_ARCHITECTURE}" != "x86_64" ] && [ -n "${ADDITIONAL_WORKER_ARCHITECTURE}" ]; then
        echo "Error: Mixed architecture cluster (${architecture} with ${ADDITIONAL_WORKER_ARCHITECTURE} worker) is not supported. Exiting."
        exit 1
    fi
    ;;
  "arm64")
    if [ "${ADDITIONAL_WORKER_ARCHITECTURE}" != "aarch64" ] && [ -n "${ADDITIONAL_WORKER_ARCHITECTURE}" ]; then
        echo "Error: Mixed architecture cluster (${architecture} with ${ADDITIONAL_WORKER_ARCHITECTURE} worker) is not supported. Exiting."
        exit 1
    fi
    ;;
esac

capi_namespace="openshift-cluster-api"
DIR=/tmp/CAPI
mkdir -p "${DIR}"
bmhlist=()

echo "[INFO] Preparing the baremetalhost resource file to add with CAPI..."
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
EOF
  fi
done

while ! oc get namespace "${capi_namespace}" 2>/dev/null; do
  echo "Waiting for ${capi_namespace} namespace to be created."
  sleep 10
done

oc get secret worker-user-data-managed -n openshift-machine-api -o yaml | sed "s/namespace: .*/namespace: ${capi_namespace}/" | oc apply -f -
oc apply -f "${DIR}/*.yaml"

replicas=${#bmhlist[@]}
infra_name=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
machinetemplate="machinetemplate"
machineset="capiset"

echo "--- Waiting for CAPI baremetalhosts to be available ---"
sleep 480
for bmhname in "${bmhlist[@]}"; do
  while ! oc get baremetalhost "${bmhname}" -n "${capi_namespace}" -o=jsonpath='{.status.provisioning.state}{"\n"}' | grep available; do
    echo "Baremetalhost ${bmhname} is not provisioned. Waiting 30 seconds..."
    sleep 30
  done
done
echo "--- CAPI baremetalhosts are available ---"

echo "--- Create Machine template Resource ---"
cat > "${DIR}/Metal3MachineTemplate.yaml" <<EOF
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
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

echo "--- Create Machine Set Resource ---"
cat > "${DIR}/Metal3MachineSet.yaml" <<EOF
apiVersion: cluster.x-k8s.io/v1beta1
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
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: Metal3MachineTemplate
        name: "${machinetemplate}"
EOF

echo "--- List all resource files ---"
more "${DIR}"/*.yaml |& sed 's/pass.*$/pass ** HIDDEN **/g'

oc create -f "${DIR}/Metal3MachineTemplate.yaml"
oc create -f "${DIR}/Metal3MachineSet.yaml"
sleep 5

if oc get baremetalhost -n "${capi_namespace}" | grep "provisioning"; then
  [ "${replicas}" -gt 1 ] && echo "--- Scale replicas ---" && \
  oc scale machineset.cluster.x-k8s.io "${machineset}" -n "${capi_namespace}" --replicas="${replicas}"
fi

echo "--- Waiting for CAPI baremetalhosts to be provisioned ---"
for bmhname in "${bmhlist[@]}"; do
  while ! oc get baremetalhost "${bmhname}" -n "${capi_namespace}" -o=jsonpath='{.status.provisioning.state}{"\n"}' | grep provisioned; do
    echo "Baremetalhost ${bmhname} is not provisioned. Waiting 60 seconds..."
    sleep 60
  done
done

echo "--- Waiting for available replicas ---"
while ! oc get machineset.cluster.x-k8s.io -n "${capi_namespace}" -o jsonpath='{.items[0].status.v1beta2.availableReplicas}{"\n"}' | grep "${replicas}"; do
  echo "${#bmhlist[@]} replicas are not available in ${machineset}. Waiting 30 seconds..."
    sleep 30
done

echo "--- Waiting for ready replicas ---"
while ! oc get machineset.cluster.x-k8s.io -n "${capi_namespace}" -o jsonpath='{.items[0].status.v1beta2.readyReplicas}{"\n"}' | grep "${replicas}"; do
  echo "${#bmhlist[@]} replicas are not available in ${machineset}. Waiting 30 seconds..."
    sleep 30
done

echo "--- CAPI worker nodes added successfully ---"
for bmhname in "${bmhlist[@]}"; do
  bmhnode=$(oc get nodes -o name | grep "${bmhname}" | awk -F/ '{print $2}')
  while ! oc get nodes "${bmhnode}" -o=jsonpath='{.status.conditions[3].status}{"\n"}' | grep "True"; do
    echo "Node ${bmhname} is not Ready. Waiting for 5 seconds..."
    sleep 5
  done
done

echo "Adding of CAPI worker nodes complete"
