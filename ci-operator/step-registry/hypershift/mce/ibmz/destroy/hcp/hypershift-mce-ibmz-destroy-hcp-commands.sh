#!/bin/bash

set -x
hcp_ns="${HC_NS}-${HC_NAME}"
export hcp_ns

echo "$(date) Scaling down nodepool ${HC_NS} to 0"
oc -n ${HC_NS} scale nodepool ${HC_NAME} --replicas 0

echo "$(date) Waiting for the compute nodes to successfully detach from the hosted cluster ${HC_NAME}"
oc wait --for=jsonpath='{.status.replicas}'=0 np/${HC_NAME} -n ${HC_NS} --timeout=10m

echo "$(date) Deleting agents from the namespace ${hcp_ns}"
agents=$(oc get agents -n ${hcp_ns} --no-headers | awk '{print $1}')
agents=$(echo "$agents" | tr '\n' ' ')
IFS=' ' read -ra agents_list <<< "$agents"
for ((i=0; i<$HYPERSHIFT_NODE_COUNT; i++)); do
    oc delete agent ${agents_list[i]} -n ${hcp_ns}
done

# Installing hypershift cli
MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
HYPERSHIFT_CLI_NAME=hcp
if (( $(echo "$MCE_VERSION < 2.4" | bc -l) )); then
    echo "MCE version is less than 2.4, use the hypershift cli name in the command"
    HYPERSHIFT_CLI_NAME=hypershift
fi

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