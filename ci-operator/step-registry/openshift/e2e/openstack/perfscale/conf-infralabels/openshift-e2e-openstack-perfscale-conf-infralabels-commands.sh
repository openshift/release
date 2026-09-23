#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# Getting all worker nodes' names
mapfile -t WORKER_NODES < <(  oc get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' | grep worker )
if [ ${#WORKER_NODES[@]} -le $INFRA_NODES_TO_TAG ]
then 
	echo "Not enough worker nodes, at least $(($INFRA_NODES_TO_TAG +1)) are needed, can not continue."
	exit 1
fi

# Adding the infra label
echo "infra nodes:"
for i in $(seq 0 $((INFRA_NODES_TO_TAG -1))); do oc label nodes/${WORKER_NODES[$i]} node-role.kubernetes.io/infra=; done

# Adding the app label to the rest of the worker nodes
echo "app nodes:"
for i in "${WORKER_NODES[@]:$INFRA_NODES_TO_TAG}"; do oc label nodes/$i node-role.kubernetes.io/app=; done

# Patching the scheduler cluster to add infra nodes as defaultNodeSelector
oc patch scheduler cluster --type='json' -p='[{"op": "add", "path": "/spec/defaultNodeSelector", "value": "node-role.kubernetes.io/infra=\"\""}]'