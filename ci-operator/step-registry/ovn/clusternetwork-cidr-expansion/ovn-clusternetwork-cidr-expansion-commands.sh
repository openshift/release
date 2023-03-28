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

if [[ "$cidr" != "10.128.0.0/14" ]] || [[ "$host_prefix" != "23" ]]; then
  echo "Error: cluster network is misconfigured. Expected CIDR of $cidr and hostPrefix of $host_prefix, but got:"
  oc get network.operator.openshift.io -o jsonpath='{.items[0].spec.clusterNetwork}'
  exit 1
fi

# patch the cluster to give it more ip space with /22
oc patch Network.config.openshift.io cluster --type='merge' --patch '{ "spec":{ "clusterNetwork": [ {"cidr":"10.128.0.0/13","hostPrefix":23} ], "networkType": "OVNKubernetes" }}'

# first wait for the network operator to move to Progressing=True
if ! oc wait co network --for='condition=PROGRESSING=True' --timeout=120s; then
  oc get co -A
  echo "Error: the network operator never moved to Progressing=True. The clusterNetwork CIDR change may not have worked" >&2
  exit 1
fi

# it can take a while for operators to roll out after the CIDR mask change. give it up to 30m
wait_for_operators_and_nodes 1800

# final state of the cluster
dump_cluster_state
