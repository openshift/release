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

  echo "************ telcov10n Clean up LVMs deployment ************"
  echo
  oc -n openshift-storage get lvmcluster,pod,sc,pv --ignore-not-found

  lvmclustername=$(oc -n openshift-storage get lvmclusters -ojsonpath='{.items[0].metadata.name}')
  if [[ "${lvmclustername}" != "" ]] ; then
    set -x
    echo
    oc -n openshift-storage delete lvmcluster ${lvmclustername}
    set +x
    echo
    echo "Success!!! The LVMs k8s service has been removed correctly."
    echo
    oc -n openshift-storage get lvmcluster,pod,sc,pv --ignore-not-found
  else
    echo "LVMs k8s didn't exist... Nothing to do"
  fi
}

function main {
  set_hub_cluster_kubeconfig
  clean_up
}

main
