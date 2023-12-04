#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

function dump_cluster_state {
  oc get nodes -o wide
  oc get network.operator.openshift.io -o yaml
  oc get machinesets -n openshift-machine-api
  oc get co -A
}

function wait_for_operators_and_nodes {
  # wait for all cluster operators to be done rolling out
  timeout $1 bash <<EOT
  until
    oc wait co --all --for='condition=AVAILABLE=True' --timeout=10s && \
    oc wait co --all --for='condition=PROGRESSING=False' --timeout=10s && \
    oc wait co --all --for='condition=DEGRADED=False' --timeout=10s && \
    oc wait node --all --for condition=Ready --timeout=10s;
  do
    sleep 10
    echo "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
  done
EOT
  if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for ClusterOperators to be ready" >&2
    dump_cluster_state
    exit 1
  fi
}

# make sure cluster is up and healthy after install and dump initial state. There are cases when not
# all operators are ready even after the install process has completed. Poll for another 15m to be
# sure and exit/fail if all operators are not healthy.
wait_for_operators_and_nodes 900
dump_cluster_state

# validate expected clusterNetwork CIDR and bail out if it's not right. want /23 so that we
# know only 8 nodes are allowed

cidr=$(oc get network.operator.openshift.io -o jsonpath='{.items[0].spec.clusterNetwork[0].cidr}')
host_prefix=$(oc get network.operator.openshift.io -o jsonpath='{.items[0].spec.clusterNetwork[0].hostPrefix}')

if [[ "$cidr" != "10.128.0.0/23" ]] || [[ "$host_prefix" != "26" ]]; then
  echo "Error: cluster network is misconfigured. Expected CIDR of $cidr and hostPrefix of $host_prefix, but got:"
  oc get network.operator.openshift.io -o jsonpath='{.items[0].spec.clusterNetwork}'
  exit 1
fi

# scale to 9 nodes. just making one of the worker machinesets has 3 more replicas
# Get the machineset list in JSON format
machinesets=$(oc get machinesets -n openshift-machine-api -o yaml)
machineset_count=$(echo "$machinesets" | /tmp/yq '.items | length')

# Make sure all nodes in the machinesets are available and ready. if not, the cluster is
# probably not healthy and just bail right away.
for i in $(seq 0 $((machineset_count-1))); do
    desired=$(echo "$machinesets" | /tmp/yq ".items[$i].spec.replicas")
    ready=$(echo "$machinesets" | /tmp/yq ".items[$i].status.readyReplicas")
    available=$(echo "$machinesets" | /tmp/yq ".items[$i].status.availableReplicas")
    name=$(echo "$machinesets" | /tmp/yq ".items[$i].metadata.name")
    if [[ "$desired" != "$ready" || "$ready" != "$available" ]]; then
        echo "Error: machine set $name has mismatched counts" >&2
        exit 1
    fi
    # Set NODE_TO_SCALE to the name of the first node in the list
    if [[ $i == 0 ]]; then
        NODE_TO_SCALE=$name
        READY_COUNT=$ready
    fi
done

echo "NODE_TO_SCALE=$NODE_TO_SCALE"
oc scale --replicas=$(($READY_COUNT + 3)) machineset "$NODE_TO_SCALE" -n openshift-machine-api

# wait for the two extra nodes to become ready, then validate that only 2 of the new nodes were allocated a subnet.
# the 3rd extra node should be notReady and have no subnet because they are exhausted
if ! oc wait machinesets -n openshift-machine-api "$NODE_TO_SCALE" --for=jsonpath='{.status.readyReplicas}'=$(($READY_COUNT + 2)) --timeout=1200s; then
    dump_cluster_state
    exit 1
fi
# machinesets are Ready, but there is a chance the final node that we expect to be notReady is not even deployed
# from the cloud provider, so let's make sure (10m) we have 9 nodes in total before we move on
timeout 600 bash <<EOT
until [ \$(oc get nodes --no-headers | wc -l) -eq 9 ]
do
  echo "Waiting to have 9 nodes\n"
  oc get nodes
  sleep 10
done
EOT

# debug info
dump_cluster_state

# check the results
oc get nodes -o jsonpath='{range.items[*]} {.metadata.name} {"\t"} {.metadata.annotations.k8s\.ovn\.org/node-subnets} {"\n"}'
node_subnet_assignments=$(oc get nodes -o jsonpath='{range.items[*]} {.metadata.name} {"\t"} {.metadata.annotations.k8s\.ovn\.org/node-subnets} {"\n"}')
nodes_with_subnet=$(echo "$node_subnet_assignments" | grep -c "default.*10.128")
nodes_without_subnet=$(echo "$node_subnet_assignments" | sed '/^[[:space:]]*$/d' | grep -vc "default.*10.128")
not_ready_node=$(oc get nodes --no-headers | grep NotReady | cut -d ' ' -f1)
num_not_ready_nodes=$(echo "$not_ready_node" | wc -l)
if [[ "$num_not_ready_nodes" -ne 1 ]]; then
  oc get nodes -o wide
  echo "Error: expected 1 node in NotReady state but found $num_not_ready_nodes." >&2
  exit 1
fi

# debug output in case we fail later
oc describe node $not_ready_node

# Check if there is exactly 1 node without a subnet and 8 nodes with a subnet
if [ "$nodes_with_subnet" -ne 8 ] || [ "$nodes_without_subnet" -ne 1 ]; then
  oc get nodes -o wide
  echo "Error: expected 8 nodes with subnets and 1 node with no subnet" >&2
  exit 1
fi
# patch the cluster to give it more ip space with /22
oc patch Network.config.openshift.io cluster --type='merge' --patch '{ "spec":{ "clusterNetwork": [ {"cidr":"10.128.0.0/22","hostPrefix":26} ], "networkType": "OVNKubernetes" }}'

# first wait for the network operator to move to Progressing=True
if ! oc wait co network --for='condition=PROGRESSING=True' --timeout=120s; then
  oc get co -A
  echo "Error: the network operator never moved to Progressing=True. The clusterNetwork CIDR change may not have worked" >&2
  exit 1
fi

# it can take a while for operators to roll out after the CIDR mask change. give it up to 30m
wait_for_operators_and_nodes 1800

# double check that 9th node became available. Should not have to wait long as it should have
# moved to Ready state during the ovnk rollout process above
oc wait machinesets -n openshift-machine-api "$NODE_TO_SCALE" --for=jsonpath='{.status.readyReplicas}'=4 --timeout=120s || true
oc get nodes -o wide
nodes_ready=$(oc get nodes --no-headers | grep -v NotReady | grep -c Ready)
if [ "$nodes_ready" -ne 9 ]; then
  oc get nodes -o wide
  echo "Error: expected 9 nodes to be Ready"
fi

# final state of the cluster
dump_cluster_state
