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

# Adding the app label to the first worker node
oc label nodes/${WORKER_NODES[0]} node-role.kubernetes.io/app=

# Adding the infra label to the rest of the worker nodes
for i in "${WORKER_NODES[@]:1}"; do oc label nodes/$i node-role.kubernetes.io/infra=; done

# Adding the defaultNodeSelector field with the appropriate node selector
SCHEDULER_CLUSTER_YAML=/tmp/scheduler.cluster.yaml
oc get scheduler cluster -o yaml > ${SCHEDULER_CLUSTER_YAML}
cat ${SCHEDULER_CLUSTER_YAML} | yq '.spec = .spec + {"defaultNodeSelector": "node-role.kubernetes.io/infra=\"\""}' | tee ${SCHEDULER_CLUSTER_YAML}.tmp 
oc apply -f ${SCHEDULER_CLUSTER_YAML}.tmp
rm -f ${SCHEDULER_CLUSTER_YAML}*