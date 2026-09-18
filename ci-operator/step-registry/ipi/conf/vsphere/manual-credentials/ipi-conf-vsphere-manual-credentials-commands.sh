#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
CONTEXT="${SHARED_DIR}/vsphere_context.sh"

if [[ ! -f "${CONFIG}" ]]; then
  echo "${CONFIG} does not exist"
  exit 1
fi

credentials_mode=$(yq-go r "${CONFIG}" credentialsMode)
if [[ "${credentials_mode}" != "Manual" ]]; then
  echo "credentialsMode must be Manual, got '${credentials_mode}'"
  exit 1
fi

if [[ ! -f "${CONTEXT}" ]]; then
  echo "${CONTEXT} does not exist"
  exit 1
fi

# shellcheck source=/dev/null
source "${CONTEXT}"
source /var/run/vault/vsphere-ibmcloud-config/load-vsphere-env-config.sh

if [[ -z "${VCENTER_AUTH_PATH:-}" || ! -f "${VCENTER_AUTH_PATH}" ]]; then
  echo "vCenter authentication configuration was not found"
  exit 1
fi

declare -a vcenter_usernames
# shellcheck disable=SC2034
declare -a vcenter_passwords
# shellcheck source=/dev/null
source "${VCENTER_AUTH_PATH}"

if [[ "${#vcenter_usernames[@]}" -ne 4 || "${#vcenter_passwords[@]}" -ne 4 ]]; then
  echo "expected exactly four vCenter usernames and passwords"
  exit 1
fi

base_vcenter=$(yq-go r -j "${CONFIG}" 'platform.vsphere.vcenters[0]')
if [[ -z "${base_vcenter}" || "${base_vcenter}" == "null" ]]; then
  echo "platform.vsphere.vcenters[0] is missing"
  exit 1
fi

vcenter=$(jq -n \
  --arg machine_user "${vcenter_usernames[0]}" \
  --arg machine_password "${vcenter_passwords[0]}" \
  --arg storage_user "${vcenter_usernames[1]}" \
  --arg storage_password "${vcenter_passwords[1]}" \
  --arg ccm_user "${vcenter_usernames[2]}" \
  --arg ccm_password "${vcenter_passwords[2]}" \
  --arg problem_detector_user "${vcenter_usernames[3]}" \
  --arg problem_detector_password "${vcenter_passwords[3]}" \
  --argjson base "${base_vcenter}" \
  '$base
   | del(.user, .password)
   | .componentCredentials = {
       machineManagement: {user: $machine_user, password: $machine_password},
       storage: {user: $storage_user, password: $storage_password},
       cloudControllerManager: {user: $ccm_user, password: $ccm_password},
       vsphereProblemDetector: {user: $problem_detector_user, password: $problem_detector_password}
     }')

patch=$(mktemp)
trap 'rm -f "${patch}"' EXIT
jq -n --argjson vcenter "${vcenter}" \
  '{platform: {vsphere: {credentialType: "component-scoped", vcenters: [$vcenter]}}}' >"${patch}"
yq-go m -x -i "${CONFIG}" "${patch}"

echo "Configured four vCenter accounts for Manual credentials mode"
