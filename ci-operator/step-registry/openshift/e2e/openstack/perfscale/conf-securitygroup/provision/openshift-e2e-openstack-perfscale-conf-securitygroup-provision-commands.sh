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

# Creating the network-perf security group
NETWORK_PERF_SG=${NETWORK_PERF_SG:-"network-perf-sg"}
echo "Creating the Security Group $NETWORK_PERF_SG"
openstack security group create $NETWORK_PERF_SG --description "Security group for running network-perf test on the Worker Nodes"
openstack security group rule create $NETWORK_PERF_SG --protocol tcp --dst-port 12865:12865 --remote-ip 0.0.0.0/0

# Adding the network-perf security group to the worker nodes
for i in "${WORKER_NODES[@]}"; do openstack server add security group $i $NETWORK_PERF_SG; done