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

function run_tests {

  echo "************ telcov10n Verifying all Policies are Healthy ************"

  set -x
  oc -n ztp-install get cgu
  oc -n openshift-gitops get apps/policies
  oc -n openshift-gitops wait apps/policies --for=jsonpath='{.status.health.status}'=Healthy --timeout 30m
  oc -n openshift-gitops get apps/policies
  oc -n ztp-install get cgu
  set +x
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

main
