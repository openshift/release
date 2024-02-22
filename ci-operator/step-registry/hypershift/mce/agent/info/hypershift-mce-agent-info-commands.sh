#!/bin/bash

set -x

source "${SHARED_DIR}/packet-conf.sh"

echo "**MGMT cluster**"
echo "HyperShift repo commit id"
oc logs -n hypershift -l app=operator --tail=-1 | head -1

echo "HyperShift install args"
oc logs -n open-cluster-management-agent-addon -l app=hypershift-addon-agent -c hypershift-addon-agent --tail=-1 | grep "HyperShift install args"

echo "cluster architecture"
oc get node -ojsonpath='{.items[*].status.nodeInfo.architecture}'

echo "multiclusterengines Version"
oc get multiclusterengines multiclusterengine-sample  -ojsonpath="{.status.currentVersion}"

echo "HyperShift supported versions"
oc get cm -n hypershift supported-versions -ojsonpath='{.data}' | jq

echo "BM node InternalIP"
oc get node -o jsonpath='{range .items[*]}Node: {@.metadata.name}  InternalIP: {@.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'

echo "AgentServiceConfig yaml"
oc get AgentServiceConfig agent -o yaml

echo "Agent State"
oc get agent -A -o jsonpath='{range .items[*]}BMH: {@.metadata.labels.agent-install\.openshift\.io/bmh} Agent: {@.metadata.name} State: {@.status.debugInfo.state}{"\n"}{end}'

echo "**Guest cluster**"
echo "HostedCluster ClusterOperators"
oc get clusteroperators

echo "HostedCluster node InternalIP"
oc get node -o jsonpath='{range .items[*]}Node: {@.metadata.name}  InternalIP: {@.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'

echo "HostedCluster ClusterVersion"
oc get clusterversion