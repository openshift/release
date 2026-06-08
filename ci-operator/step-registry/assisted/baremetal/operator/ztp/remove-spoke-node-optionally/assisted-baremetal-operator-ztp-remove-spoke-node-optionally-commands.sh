#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp remove spoke node optionally command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -o xtrace
set -o pipefail

echo "### Sourcing root config."
source /root/config

echo "### Injecting ZTP configuration."
# Inject job configuration for ZTP, if available
if [[ -e /root/assisted-ztp-config ]]
then
  source /root/assisted-ztp-config
fi

if [ -z "${REMOVE_SPOKE_NODE}" ]; then
	echo "Not removing agent spoke node"
	exit 0
fi

SPOKE_NAMESPACE="${SPOKE_NAMESPACE:-assisted-spoke-cluster}"

# Get a worker agent
agent_name=$(oc get agent --namespace ${SPOKE_NAMESPACE} -ojson | jq --raw-output 'first(.items[] | select(.status.role == "worker")) | .metadata.name')
if [ -z "${agent_name}" ]; then
	echo "No worker agents found"
	exit 1
fi
echo "Using agent ${agent_name}"
agent_json=$(oc get agent --namespace ${SPOKE_NAMESPACE} -ojson ${agent_name})

bmh_name=$(echo ${agent_json} | jq --raw-output '.metadata.labels."agent-install.openshift.io/bmh" | select (. != null)')
if [ -z "${bmh_name}" ]; then
	echo "No bmh found for agent ${agent_name}"
	exit 1
fi
echo "Using bmh ${bmh_name}"

# get agent hostname (node name)
node_name=$(echo ${agent_json} | jq -r '.spec.hostname | select (. != null)')
if [ -z "${node_name}" ]; then
	node_name=$(echo ${agent_json} | jq -r '.status.inventory.hostname | select (. != null)')
fi
if [ -z "${node_name}" ]; then
	echo "Could not determine node name for agent ${agent_name}"
	exit 1
fi

echo "Annotating BMH to delete spoke node on removal"
oc annotate --overwrite --namespace ${SPOKE_NAMESPACE} bmh ${bmh_name} bmac.agent-install.openshift.io/remove-agent-and-node-on-delete=true

# wait 10 seconds for the finalier to appear
echo "waiting up to 10 seconds for BMH finalizer to be set"
for i in {1..10}; do
	oc get -ojson --namespace ${SPOKE_NAMESPACE} bmh ${bmh_name} | jq -e '.metadata.finalizers | any(. == "bmac.agent-install.openshift.io/deprovision")' && break || sleep 1
done
oc get -ojson --namespace ${SPOKE_NAMESPACE} bmh ${bmh_name} | jq -e '.metadata.finalizers | any(. == "bmac.agent-install.openshift.io/deprovision")' || { echo "BMH deprovision finalizer not found" ; exit 1; }

# delete BMH
oc delete --namespace ${SPOKE_NAMESPACE} --wait=false bmh ${bmh_name}

# get spoke kubeconfig
cd_name=$(echo ${agent_json} | jq -r '.spec.clusterDeploymentName.name')
spoke_kubeconfig_secret_name=$(oc get clusterdeployment --namespace ${SPOKE_NAMESPACE} ${cd_name} -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}')
oc extract --namespace ${SPOKE_NAMESPACE} secret/${spoke_kubeconfig_secret_name} --to=- --keys=kubeconfig > /tmp/spoke-kubeconfig

# configure /etc/hosts for spoke cluster access
aci_name=$(oc get --namespace ${SPOKE_NAMESPACE} clusterdeployment ${cd_name} -o jsonpath='{.spec.clusterInstallRef.name}')
api_ip=$(oc get --namespace ${SPOKE_NAMESPACE} agentclusterinstall ${aci_name} -o jsonpath='{.status.apiVIP}')

cluster_name=$(oc get -n ${SPOKE_NAMESPACE} clusterdeployment ${cd_name} -o jsonpath='{.spec.clusterName}')
base_domain=$(oc get -n ${SPOKE_NAMESPACE} clusterdeployment ${cd_name} -o jsonpath='{.spec.baseDomain}')

echo "${api_ip} api.${cluster_name}.${base_domain}" >> /etc/hosts

# wait for spoke node to be removed
oc --kubeconfig=/tmp/spoke-kubeconfig wait --for=delete --timeout=30m node/${node_name} || { echo "Timed out waiting for node ${node_name} to be deleted" ; exit 1; }
EOF
