#!/bin/bash

set -x
HC_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HC_NAME
hcp_ns="${HC_NS}-${HC_NAME}"
export hcp_ns

echo "$(date) Scaling down nodepool ${HC_NS} to 0"
oc -n ${HC_NS} scale nodepool ${HC_NAME} --replicas 0

# WA for nodes not detaching while scaling down (BUG : https://issues.redhat.com/browse/HOSTEDCP-1427)
job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
detach_nodes() {
    echo 'Deleting the nodes forcefully by patching the machines finalizers'
    machines=$(oc get machines.cluster.x-k8s.io -n $hcp_ns --no-headers | awk '{print $1}')
    machines=$(echo "$machines" | tr '\n' ' ')
    echo "Machines : $machines"
    IFS=' ' read -ra machines_list <<< "$machines"
    echo "Machines List : ${machines_list[*]}"
    for ((i=0; i<$HYPERSHIFT_NODE_COUNT; i++)); do
        oc delete node compute-$i.$job_id-$HYPERSHIFT_BASEDOMAIN --kubeconfig "${SHARED_DIR}/nested_kubeconfig"
        oc patch machine.cluster.x-k8s.io ${machines_list[i]} -n "$hcp_ns" -p '{"metadata":{"finalizers":null}}' --type=merge
    done
}

echo "$(date) Waiting for the compute nodes to successfully detach from the hosted cluster ${HC_NAME}"
oc wait --for=jsonpath='{.status.replicas}'=0 np/${HC_NAME} -n ${HC_NS} --timeout=10m || detach_nodes

echo "$(date) Deleting agents from the namespace ${hcp_ns}"
agents=$(oc get agents -n ${hcp_ns} --no-headers | awk '{print $1}')
agents=$(echo "$agents" | tr '\n' ' ')
IFS=' ' read -ra agents_list <<< "$agents"
for ((i=0; i<$HYPERSHIFT_NODE_COUNT; i++)); do
    oc delete agent ${agents_list[i]} -n ${hcp_ns}
done

# Installing hypershift cli
HYPERSHIFT_CLI_NAME=hcp

echo "$(date) Installing hypershift cli"
mkdir /tmp/${HYPERSHIFT_CLI_NAME}_cli
downloadURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_CLI_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz ${downloadURL}
tar -xvf /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz -C /tmp/${HYPERSHIFT_CLI_NAME}_cli
chmod +x /tmp/${HYPERSHIFT_CLI_NAME}_cli/${HYPERSHIFT_CLI_NAME}
export PATH=$PATH:/tmp/${HYPERSHIFT_CLI_NAME}_cli

echo "$(date) Triggering the hosted cluster ${HC_NAME} deletion"
${HYPERSHIFT_CLI_NAME} destroy cluster agent --name ${HC_NAME} --namespace ${HC_NS}
echo "$(date) Hosted cluster ${HC_NAME} deletion is successful"
