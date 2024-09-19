#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version

ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")
export ES_PASSWORD
export ES_USERNAME

export ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"



echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config
export KRKN_KUBE_CONFIG=$KUBECONFIG

# read passwords from vault
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
#aws_access_key_id=$(cat "/secret/telemetry/aws_access_key_id")
#aws_secret_access_key=$(cat "/secret/telemetry/aws_secret_access_key")

# set the secrets from the vault as env vars
export TELEMETRY_PASSWORD=$telemetry_password

platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}') 
if [ "$platform" = "AWS" ]; then
    mkdir -p $HOME/.aws
    cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    export AWS_DEFAULT_REGION=us-west-2
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
    region="${LEASED_RESOURCE}"
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


ls node-disruptions

./node-disruptions/prow_run.sh
rc=$?
echo "Finished running node disruptions"
echo "Return code: $rc"
