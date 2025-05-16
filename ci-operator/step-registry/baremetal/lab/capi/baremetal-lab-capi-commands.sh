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
echo "[INFO] Preparing the baremetalhost list to add with CAPI..."

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "${bmhost}" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]]; then
    echo "Prepare yaml files for ${name}"
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
    address: "${bmc_scheme}://${bmc_address}${bmc_base_uri}"
    credentialsName: "${name}-bmc-secret"
    disableCertificateVerification: true

EOF
  fi
done

while ! oc get namespace openshift-cluster-api 2>/dev/null; do
  echo "Waiting for ${capi_namespace} namespace to be created."
  sleep 10
done
oc get secret worker-user-data-managed -n openshift-machine-api -o yaml | sed "s/namespace: .*/namespace: ${capi_namespace}/" | oc apply -f -
oc apply -k /tmp/"${DIR}"

echo "--- Waiting for baremetalhost baremetalhosts to be provisioned ---"
bmhlist=$(find /tmp/"${DIR}" -name "*.yaml" | awk -F"." '{print $1}')
for bmhname in ${bmhlist}; do
  while ! oc get baremetalhost "${bmhname}" -n "${capi_namespace}" -o=jsonpath='{.status.provisioning.state}' | grep provisioned; do
    echo "Waiting for baremetalhost ${bmhname} to be provisioned"
    sleep 30
  done
done

#for bmhname in "${bmhlist}"; do
#  while ! oc get nodes ${bmhname} -o=jsonpath='{.status.conditions[3].status}' | grep "True"; do
#    echo "Waiting for node ${bmhname} to be provisioned"
#    sleep 30
#  done
#done
