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

  echo "************ telcov10n Clean up Gitea deployment ************"
  set -x
  helm uninstall gitea -n ${GITEA_NAMESPACE} || echo "Gitea k8s service didn't exist..."
  oc delete ns ${GITEA_NAMESPACE} || echo "Gitea k8s namespace didn't exist..."
  set +x
}

function main {
  set_hub_cluster_kubeconfig
  clean_up

  echo
  echo "Success!!! The Gitea k8s service has been removed correctly."
}

main
