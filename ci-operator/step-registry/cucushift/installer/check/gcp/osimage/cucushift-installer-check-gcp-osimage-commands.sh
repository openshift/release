#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

if [[ "${COMPUTE_OSIMAGE}" == "" ]] && [[ "${CONTROL_PLANE_OSIMAGE}" == "" ]] && [[ "${DEFAULT_MACHINE_OSIMAGE}" == "" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Nothing to do, abort." && exit 0
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
echo "$(date -u --rfc-3339=seconds) - INFO: cluster name: ${CLUSTER_NAME}"

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

dir=$(mktemp -d)
pushd "${dir}"

CPMS_REQUIRED_OCP_VERSION="4.13"
version=$(oc version -ojson | jq -r '.openshiftVersion' | cut -d. -f 1,2)
echo "OCP version: ${version}"

# check if controlplanemachinesets is supported by the IaaS and the OCP version
# return 0 if controlplanemachinesets is supported, otherwise 1
function hasCPMS() {
    ret=1

    if [ -n "${version}" ] && [ "$(printf '%s\n' "${CPMS_REQUIRED_OCP_VERSION}" "${version}" | sort --version-sort | head -n1)" = "${CPMS_REQUIRED_OCP_VERSION}" ]; then
        ret=0
    fi
    return ${ret}
}

## The expected OS image
url_prefix="https://www.googleapis.com/compute/v1/projects/"
expected_compute_image=""
if [ -n "${COMPUTE_OSIMAGE}" ]; then
  expected_compute_image="${url_prefix}${COMPUTE_OSIMAGE##*projects/}"
elif [ -n "${DEFAULT_MACHINE_OSIMAGE}" ]; then
  expected_compute_image="${url_prefix}${DEFAULT_MACHINE_OSIMAGE##*projects/}"
fi
echo "$(date -u --rfc-3339=seconds) - INFO: The expected OS image of worker machines: ${expected_compute_image}"

expected_control_plane_image=""
if [ -n "${CONTROL_PLANE_OSIMAGE}" ]; then
  expected_control_plane_image="${url_prefix}${CONTROL_PLANE_OSIMAGE##*projects/}"
elif [ -n "${DEFAULT_MACHINE_OSIMAGE}" ]; then
  expected_control_plane_image="${url_prefix}${DEFAULT_MACHINE_OSIMAGE##*projects/}"
fi
echo "$(date -u --rfc-3339=seconds) - INFO: The expected OS image of control-plane machines: ${expected_control_plane_image}"

## The OS images settings in worker machinesets and control-plane machinesets (CPMS)
# https://issues.redhat.com/browse/OCPBUGS-57348 Cluster manages bootimages despite explicit bootimages in installconfig
worker_machineset_osimage=$(oc get machinesets.machine.openshift.io -n openshift-machine-api -ojson | jq -r '.items[] | .spec.template.spec.providerSpec.value.disks[].image' | sort | uniq)
worker_machineset_osimage="${url_prefix}${worker_machineset_osimage##*projects/}"
echo "$(date -u --rfc-3339=seconds) - INFO: OS image in Worker MachineSets: ${worker_machineset_osimage}"

if hasCPMS; then
  controlplanemachineset_osimage=$(oc get controlplanemachineset.machine.openshift.io -n openshift-machine-api -ojson | jq -r '.items[] | .spec.template."machines_v1beta1_machine_openshift_io".spec.providerSpec.value.disks[].image')
  controlplanemachineset_osimage="${url_prefix}${controlplanemachineset_osimage##*projects/}"
  echo "$(date -u --rfc-3339=seconds) - INFO: OS image in Control-plane MachineSet: ${controlplanemachineset_osimage}"
else
  controlplanemachineset_osimage=""
  echo "$(date -u --rfc-3339=seconds) - INFO: 'controlplanemachinesets' is not supproted (OCP ${version} on GCP)."
fi

## Try the validation
ret=0

if [ -n "${expected_compute_image}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Checking OS images of compute nodes..."
  if [[ "${worker_machineset_osimage}" != "${expected_compute_image}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - FAILED: Compute OS image mismatch - wrong worker machinesets osimage."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - PASSED: Compute OS image does match - correct worker machinesets osimage."
  fi
  readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,sourceImage)" | grep worker)
  for line in "${disks[@]}"; do
    name="${line%% *}"
    source_image="${line##* }"
    echo "$(date -u --rfc-3339=seconds) - INFO: Machine '${name}', sourceImage '${source_image}'"
    if [[ "${source_image}" != "${expected_compute_image}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - FAILED: Compute OS image mismatch - wrong sourceImage."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - PASSED: Compute OS image does match - correct sourceImage."
    fi
  done
fi

if [ -n "${expected_control_plane_image}" ]; then
  echo "$(date -u --rfc-3339=seconds) - Checking OS images of control-plane nodes..."
  if [[ -n "${controlplanemachineset_osimage}" ]]; then
    if [[ "${controlplanemachineset_osimage}" != "${expected_control_plane_image}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - FAILED: Control-plane OS image mismatch - wrong CPMS osimage."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - PASSED: Control-plane OS image does match - correct CPMS osimage."
    fi
  fi
  readarray -t disks < <(gcloud compute disks list --filter="${CLUSTER_NAME}" --format="table(name,sourceImage)" | grep master)
  for line in "${disks[@]}"; do
    name="${line%% *}"
    source_image="${line##* }"
    echo "$(date -u --rfc-3339=seconds) - INFO: Machine '${name}', sourceImage '${source_image}'"
    if [[ "${source_image}" != "${expected_control_plane_image}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - FAILED: Control-plane OS image mismatch - wrong sourceImage."
      ret=1
    else
      echo "$(date -u --rfc-3339=seconds) - PASSED: Control-plane OS image does match - correct sourceImage."
    fi
  done
fi

popd
exit ${ret}
