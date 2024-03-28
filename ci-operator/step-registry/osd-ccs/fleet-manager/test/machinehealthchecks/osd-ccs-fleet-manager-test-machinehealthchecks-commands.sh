#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

OSDFM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/fleetmanager-token")
if [[ ! -z "${OSDFM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OSDFM_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token OSDFM_TOKEN!"
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
echo "Test: OCP-68672 - [OCM-3186] Validate existing MachineHealthChecks replace machines in request serving pools"

echo "Get number of nodes before HC was deleted"

ORIGINAL_NUMBER_OF_NODES=$(cat "${SHARED_DIR}/osd-fm-mc-node_count")

function check_nodes_count () {
  TIMEOUT_COUNTER=90
  GOT_NODE_COUNT_MATCH=false
  for ((i=0; i<TIMEOUT_COUNTER; i+=1)); do
    echo "Check if MHC restored nodes on an MC"
    CURRENT_NUMBER_OF_NODES=$(oc get nodes -A --no-headers | wc -l | tr -d ' ')
    if [ "$CURRENT_NUMBER_OF_NODES" -eq "$ORIGINAL_NUMBER_OF_NODES" ]; then
      GOT_NODE_COUNT_MATCH=true
      break
    fi
    echo "Expected number of nodes is: '$ORIGINAL_NUMBER_OF_NODES'. Currently at: '$CURRENT_NUMBER_OF_NODES'. Sleep for 10 seconds"
    sleep 10
  done
  if [ "$GOT_NODE_COUNT_MATCH" = true ]; then
    echo "Nodes count restored to desired count"
  else
    echo "Nodes count not restored to desired count"
    exit 1
  fi
}

check_nodes_count
