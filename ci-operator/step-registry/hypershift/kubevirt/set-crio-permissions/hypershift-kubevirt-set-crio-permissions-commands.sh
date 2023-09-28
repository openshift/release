#!/bin/bash

set -ex

DEBUG_NS=debug-ns
oc create ns ${DEBUG_NS}
oc label ns ${DEBUG_NS} security.openshift.io/scc.podSecurityLabelSync=false --overwrite
oc label ns ${DEBUG_NS} pod-security.kubernetes.io/enforce=privileged --overwrite

NODES=$(oc get nodes -o json | jq -r .items[].metadata.name)

while IFS= read -r node
do
	echo "setting device_ownership_from_security_context for ${node}.."
	oc debug node/${node} --to-namespace ${DEBUG_NS} -- chroot /host sed -i '/^\[crio\.runtime\]/a device_ownership_from_security_context = true' /etc/crio/crio.conf
	echo "restarting crio service on ${node}"
	oc debug node/${node} --to-namespace ${DEBUG_NS} -- chroot /host systemctl restart crio
done <<< "${NODES}"
