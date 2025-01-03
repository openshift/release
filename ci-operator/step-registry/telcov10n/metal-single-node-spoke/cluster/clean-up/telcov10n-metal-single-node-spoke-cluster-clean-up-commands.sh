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

  echo "************ telcov10n Clean up SNO Spoke cluster artefacts ************"

  if [ -f "${SHARED_DIR}/spoke_cluster_name" ]; then
    SPOKE_CLUSTER_NAME="$(cat ${SHARED_DIR}/spoke_cluster_name)"
  else
    SPOKE_CLUSTER_NAME=${NAMESPACE}
  fi

  set -x
  oc -n ${SPOKE_CLUSTER_NAME} delete agentclusterinstalls.extensions.hive.openshift.io ${SPOKE_CLUSTER_NAME} || echo

  if [ -n "${CATALOGSOURCE_NAME}" ]; then
    oc -n openshift-marketplace delete catsrc ${CATALOGSOURCE_NAME} --ignore-not-found
  fi
  set +x
}

function main {
  set_hub_cluster_kubeconfig
  clean_up

  echo
  echo "Success!!! The SNO Spoke cluster related objects have been removed correctly."
}

main
