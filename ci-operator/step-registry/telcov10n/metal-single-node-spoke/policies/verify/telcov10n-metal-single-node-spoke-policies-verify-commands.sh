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
  oc -n openshift-gitops wait apps/policies --for=jsonpath='{.status.health.status}'=Healthy --timeout 30m
  set +x
}

function main {
  set_hub_cluster_kubeconfig
  run_tests

  echo
  echo "Success!!! The Policies have been pushed correctly."
}

main
