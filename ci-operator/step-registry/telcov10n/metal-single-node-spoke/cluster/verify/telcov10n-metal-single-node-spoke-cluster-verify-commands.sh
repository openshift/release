#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Get Hub kubeconfig from \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"
}

function validate_host_firmware_settings {

  SPOKE_CLUSTER_NAME=${NAMESPACE}

  local hostname_with_base_domain
  hostname_with_base_domain="$(cat ${SHARED_DIR}/hostname_with_base_domain)"

  local config_bios_settings
  local current_bios_settings
  local mismatch_found
  mismatch_found="no"

  if [ "${BIOS_VALIDATIONS}" != "{}" ]; then
    set +x
    current_bios_settings="$(yq -o=json <<< "$( \
      oc -n ${SPOKE_CLUSTER_NAME} get HostFirmwareSettings ${hostname_with_base_domain} -oyaml)" \
        | jq -c '.status.settings')"
    config_bios_settings="$(jq -c '.' <<< "$( \
      yq -o=json '.' <<< "$(echo "${BIOS_VALIDATIONS}" | sed '/^\s*#/d; /^\s*$/d; s/^[ \t]*//')")")"

    echo
    echo "Checking the following BIOS settings..."
    echo "-----------------------------------------"
    echo "${config_bios_settings}" | jq
    echo "-----------------------------------------"
    while IFS= read -r kv; do
      key="${kv%%=*}"
      val="${kv#*=}"

      # Get the value from file2 for the same key
      val2="$(echo "${current_bios_settings}" | jq -r --arg key "$key" '.[$key]')"

      # If values don't match or key doesn't exist
      if [[ "$val2" != "$val" ]]; then
        echo "Mismatch or missing key: '$key' -> expected: '$val' <-> current: '${val2:="NOT FOUND"}'"
        mismatch_found="yes"
      fi
    done <<< "$(echo "${config_bios_settings}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')"

    [ "${mismatch_found}" == "yes" ] && {
      echo "-----------------------------------------" ;
      exit 1 ;
    }
  fi

  echo "All BIOS attributes are the expected ones"
  echo "-----------------------------------------"
  echo "${hostname_with_base_domain} HostFirmwareSettings after patch:"
  echo "-----------------------------------------------------------------"
  set -x
  oc -n ${SPOKE_CLUSTER_NAME} get HostFirmwareSettings "${hostname_with_base_domain}" -oyaml
  set +x
  echo
}

function run_tests {
  echo "************ telcov10n Verifying installation ************"

  oc get managedcluster || echo "No ready..."

  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig
  secret_adm_pass=${SPOKE_CLUSTER_NAME}-admin-password

  echo "username: kubeadmin" >| ${SHARED_DIR}/admin-pass-${SPOKE_CLUSTER_NAME}.yaml
  echo "password: $(cat ${SHARED_DIR}/spoke-${secret_adm_pass}.yaml)" \
    >> ${SHARED_DIR}/admin-pass-${SPOKE_CLUSTER_NAME}.yaml

  if [ -n "${PULL_NUMBER:-}" ]; then
    echo
    echo "------------------------ Spoke Details --------------------------------------------------------"
    echo "OCP Installed Version:"
    oc --kubeconfig ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml get clusterversions.config.openshift.io
    echo
    echo "kubeconfig: export KUBECONFIG=${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml"
    echo "Console: $(oc --kubeconfig ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml whoami --show-console)"
    cat ${SHARED_DIR}/admin-pass-${SPOKE_CLUSTER_NAME}.yaml
  fi
}

function main {
  set_hub_cluster_kubeconfig
  validate_host_firmware_settings
  run_tests

  echo
  echo "Success!!! The SNO Spoke cluster has been verified."
}

main
