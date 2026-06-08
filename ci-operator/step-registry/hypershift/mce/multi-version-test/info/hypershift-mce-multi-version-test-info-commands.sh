#!/bin/bash

set -ex

echo "MGMT cluster version"
oc get clusterversion

echo "MCE version"
oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}"

echo "HyperShift Operator Version"
oc logs -n hypershift -lapp=operator --tail=-1 -c operator | head -1 | jq

echo "HostedCluster version"
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" && oc get clusterversion