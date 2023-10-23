#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# patch the network operator
oc patch Network.operator.openshift.io cluster --type='merge' --patch '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"hybridOverlayConfig":{"hybridClusterNetwork":[{"cidr": "10.132.0.0/14","hostPrefix": 23}]}}}}}'

# wait for the ovnkube config map to reflect the change
start_time=$(date +%s)
while [ -z "$(oc get configmap -n openshift-ovn-kubernetes ovnkube-config -o yaml | grep hybridoverlay)" ]; do
	if [ $(($(date +%s) - $start_time)) -gt 300 ]; then
		echo "Timeout waiting for the ovn-kubernetes config map to update"
		exit 1
	fi
done

# verify that the ovnkube-master pods come back up
start_time=$(date +%s)
while [ "$(oc get daemonset.apps/ovnkube-master -n openshift-ovn-kubernetes | awk '{print $2==$4}' | tail -n +2)" -ne 1 ]; do
	if [ $(($(date +%s) - $start_time)) -gt 300 ]; then
		echo "Timeout waiting for the ovn-kubernetes master pods to come up"
		exit 1
	fi
done

# verify that the ovnkube-node pods come back up
start_time=$(date +%s)
while [ "$(oc get daemonset.apps/ovnkube-node -n openshift-ovn-kubernetes | awk '{print $2==$4}' | tail -n +2)" -ne 1 ]; do
	if [ $(($(date +%s) - $start_time)) -gt 300 ]; then
		echo "Timeout waiting for the ovn-kubernetes master pods to come up"
		exit 1
	fi
done

