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
if [ ${#WORKER_NODES[@]} -lt 3 ]
then 
	echo "Not enough worker nodes, at least three are needed, can not continue."
	exit 1
fi

# Adding the app label to the first worker node
oc label nodes/${WORKER_NODES[0]} node-role.kubernetes.io/app=

# Adding the infra label to the rest of the worker nodes
for i in "${WORKER_NODES[@]:1}"; do oc label nodes/$i node-role.kubernetes.io/infra=; done

# Patching the scheduler cluster to add infra nodes as defaultNodeSelector
oc patch scheduler cluster --type='json' -p='[{"op": "add", "path": "/spec/defaultNodeSelector", "value": "node-role.kubernetes.io/infra=\"\""}]'