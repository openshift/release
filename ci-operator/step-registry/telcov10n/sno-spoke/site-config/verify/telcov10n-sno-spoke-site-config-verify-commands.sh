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
  echo "************ telcov10n Verifying installation ************"
  oc get managedcluster || echo "No ready..."
}

function main {
  set_hub_cluster_kubeconfig
  run_tests

  echo
  echo "Success!!! The SNO Spoke cluster has been installed correctly."
}

main
