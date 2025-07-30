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
  oc get policies.policy.open-cluster-management.io -A | grep "${ns_tail}"
  set +x

}

function run_tests {

  echo "************ telcov10n Verifying all Policies are Healthy ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}
  ns_padded="000${SPOKE_CLUSTER_NAME}"
  ns_tail="${ns_padded: -4}"

  show_current_policies_status

  wait_until_command_is_ok \
    "(
      oc -n openshift-gitops get apps/policies -ojsonpath='{.status.resources}' | jq '
        .[]
        | select( .kind == \"Policy\" )
        | select( .namespace | endswith(\"${ns_tail}\") )
        | .health.status' \
      || echo \
    ) \
    | grep -v 'Healthy' \
    ; [ \$? -ne 0 ]" \
    ${POLICIES_STATUS_CHECK_CADENDE} ${POLICIES_STATUS_CHECK_ATTEMPTS}

  # wait_until_command_is_ok \
  #   "! oc get policies.policy.open-cluster-management.io -A | \
  #       grep '${SPOKE_CLUSTER_NAME}' | \
  #       grep -v -w 'Compliant' | \
  #       grep -q ." \
  #   ${POLICIES_STATUS_CHECK_CADENDE} ${POLICIES_STATUS_CHECK_ATTEMPTS}

  # set -x
  # oc -n openshift-gitops wait apps/policies \
  #   --for=jsonpath='{.status.health.status}'=Healthy \
  #   --timeout ${POLICIES_HEALTHY_TIMEOUT}
  # set +x

  #                        NAME  UPDATED UPDATING DEGRADED MACHINECOUNT READYMACHINECOUNT UPDATEDMACHINECOUNT DEGRADEDMACHINECOUNT
  # TODO: it should be on the Spoke cluster. But validation policies do this already:
  # https://gitea-ztp-gitea.apps.hub-4-19.ztp-left-shifting.kpi.telco.lab/gitea/telcov10n/src/branch/main/site-policies/spoke-4-19/source-crs/validatorCRs/informDuValidator.yaml
  # wait_until_command_is_ok "oc get mcp master |grep ' True.* False .* False .* 1 .* 1 .* 1 .* 0'" ${POLICIES_STATUS_CHECK_CADENDE} 30
  # wait_until_command_is_ok "oc get mcp worker |grep ' True.* False .* False .* 0 .* 0 .* 0 .* 0'" ${POLICIES_STATUS_CHECK_CADENDE} 30

  show_current_policies_status
}

function are_there_polices_to_be_verified {

  num_of_policies=$(jq -c '.[]' <<< "$(yq -o json <<< ${PGT_RELATED_FILES})"|wc -l)
  if [[ "${num_of_policies}" == "0" ]]; then
    echo "no"
  else
    echo "yes"
  fi
}

function main {
  if [[ "$(are_there_polices_to_be_verified)" == "yes" ]]; then
    echo
    echo "Verifying defined policies..."
    echo

    set_hub_cluster_kubeconfig
    run_tests

    echo
    echo "Success!!! The Policies have been pushed correctly."
  else
    echo
    echo "No policies were defined..."
    echo
  fi
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
