#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Get Hub kubeconfig from \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"
}

function show_current_policies_status {

  set -x
  oc -n ztp-install get cgu
  oc -n openshift-gitops get apps/policies
  oc get policies.policy.open-cluster-management.io -A | grep "${SPOKE_CLUSTER_NAME}"
  set +x

}

function run_tests {

  echo "************ telcov10n Verifying all Policies are Healthy ************"

  if [ -f "${SHARED_DIR}/spoke_cluster_name" ]; then
    SPOKE_CLUSTER_NAME="$(cat ${SHARED_DIR}/spoke_cluster_name)"
  else
    SPOKE_CLUSTER_NAME=${NAMESPACE}
  fi

  show_current_policies_status

  wait_until_command_is_ok \
    "! oc get policies.policy.open-cluster-management.io -A | grep '${SPOKE_CLUSTER_NAME}' | grep -v -w 'Compliant' | grep -q ." \
    ${POLICIES_STATUS_CHECK_CADENDE} ${POLICIES_STATUS_CHECK_ATTEMPTS}

  # set -x
  # oc -n openshift-gitops wait apps/policies \
  #   --for=jsonpath='{.status.health.status}'=Healthy \
  #   --timeout ${POLICIES_HEALTHY_TIMEOUT}
  # set +x

  #                        NAME  UPDATED UPDATING DEGRADED MACHINECOUNT READYMACHINECOUNT UPDATEDMACHINECOUNT DEGRADEDMACHINECOUNT
  wait_until_command_is_ok "oc get mcp master |grep ' True.* False .* False .* 1 .* 1 .* 1 .* 0'" ${POLICIES_STATUS_CHECK_CADENDE} 30
  wait_until_command_is_ok "oc get mcp worker |grep ' True.* False .* False .* 0 .* 0 .* 0 .* 0'" ${POLICIES_STATUS_CHECK_CADENDE} 30

  show_current_policies_status
}

function main {
  set_hub_cluster_kubeconfig
  run_tests

  echo
  echo "Success!!! The Policies have been pushed correctly."
}

function on_failed {

  ext_code=$? ; [ $ext_code -eq 0 ] && return
  show_current_policies_status

  set -x
  oc --kubeconfig "$(ls -1 ${SHARED_DIR}/spoke-*kubeconfig*)" get node,mcp -owide || echo
  set +x
}

trap on_failed EXIT
main
