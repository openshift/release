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

function clean_up {

  echo "************ telcov10n Clean up Gitops deployment ************"
  set -x
  oc -n openshift-gitops delete apps clusters policies || echo "Gitops k8s apps didn't exist..."
  set +x
}

function main {
  set_hub_cluster_kubeconfig
  clean_up

  echo
  echo "Success!!! The Gitops k8s service has been removed correctly."
}

main
