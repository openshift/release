#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

oc config view
oc projects

# Create infra-nodes for ingress-perf testing
if [ ${INFRA} == "true" ]; then
  if [[ $(oc get nodes -l node-role.kubernetes.io/infra= --no-headers | wc -l) != 2 ]]; then
    for node in `oc get nodes -l node-role.kubernetes.io/worker= --no-headers | head -2 | awk '{print $1}'`; do
      oc label node $node node-role.kubernetes.io/infra=""
      oc label node $node node-role.kubernetes.io/worker-;
    done
  fi
fi

if [ ${TELCO} == "true" ]; then
# Label the nodes
  if [ ${LABEL} ]; then
    for node in $(oc get node -oname -l node-role.kubernetes.io/worker | head -n ${LABEL_NUM_NODES} | grep -oP "^node/\K.*")
    do
      oc label node $node ${LABEL}="" --overwrite
    done
  fi
fi