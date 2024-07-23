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

  echo "************ telcov10n Clean up AgentServiceConfig CR ************"
  set -x
  oc delete AgentServiceConfig agent || echo "The CR didn't exist..."
  assisted_service_pod_name=$(oc -n multicluster-engine get pods --no-headers -o custom-columns=":metadata.name" | \
    grep "^assisted-service" || echo "assisted-service")
  oc -n multicluster-engine wait --for=delete pod/assisted-image-service-0 pod/${assisted_service_pod_name} --timeout=30m
  set +x
}


function main {
  set_hub_cluster_kubeconfig
  clean_up

  echo
  echo "Success!!! The SNO Spoke cluster CRs have been removed correctly."
}

main
