#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls
while [ ! -f "${KUBECONFIG}" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
  sleep 30
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
echo "kubeconfig loc $KUBECONFIG"
echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config
export KRKN_KUBE_CONFIG=$KUBECONFIG
while [ "$(oc get ns | grep -c 'start-kraken')" -lt 1 ]; do
  echo "start kraken not found yet, waiting"
  sleep 10
done
echo "starting node disruption scenario"

# List of nodes
nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')

# Check if nodes were found
if [[ -z "$nodes" ]]; then
  echo "No nodes found in the cluster."
  exit 1
fi

# Select the first node
node_name=$(echo $nodes | awk '{print $1}')

# Get the region label for the selected node
node_region=$(oc get node "$node_name" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/region}')

# Check if the region label was found
if [[ -z "$node_region" ]]; then
  echo "Region label not found for node $node_name."
  exit 1
fi

# Assign region
REGION=$node_region

platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}') 
if [ "$platform" = "AWS" ]; then
    mkdir -p $HOME/.aws
    cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    aws_region=$REGION
    export AWS_DEFAULT_REGION=$aws_region
elif [ "$platform" = "GCP" ]; then
    export CLOUD_TYPE="gcp"
    export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
elif [ "$platform" = "Azure" ]; then
    export CLOUD_TYPE="azure"
    export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
    # jq is not available in the ci image...
    AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId ${AZURE_AUTH_LOCATION})"
    export AZURE_SUBSCRIPTION_ID
    AZURE_TENANT_ID="$(jq -r .tenantId ${AZURE_AUTH_LOCATION})"
    export AZURE_TENANT_ID
    AZURE_CLIENT_ID="$(jq -r .clientId ${AZURE_AUTH_LOCATION})"
    export AZURE_CLIENT_ID
    AZURE_CLIENT_SECRET="$(jq -r .clientSecret ${AZURE_AUTH_LOCATION})"
    export AZURE_CLIENT_SECRET
elif [ "$platform" = "IBMCloud" ]; then
# https://github.com/openshift/release/blob/3afc9cb376776ca27fbb1a4927281e84295f4810/ci-operator/step-registry/openshift-extended/upgrade/pre/openshift-extended-upgrade-pre-commands.sh#L158
    IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_CLI
    IBMCLOUD_HOME=/output
    export IBMCLOUD_HOME
    region="${REGION}"
    CLOUD_TYPE="ibmcloud"
    export CLOUD_TYPE
    export region
    IBMC_URL="https://${region}.iaas.cloud.ibm.com/v1"
    export IBMC_URL
    IBMC_APIKEY=$(cat ${CLUSTER_PROFILE_DIR}/ibmcloud-api-key)
    export IBMC_APIKEY
    ACTION="$CLOUD_TYPE-node-reboot"
    export ACTION
    NODE_NAME=$(oc get nodes -l $LABEL_SELECTOR --no-headers | head -1 | awk '{printf $1}' )
    export NODE_NAME
    export TIMEOUT=320

fi
./node-disruptions/prow_run.sh
# rc=$?
echo "Done running the test!" 
exit 0