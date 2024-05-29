#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config
export KRKN_KUBE_CONFIG=$KUBECONFIG

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred

platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}') 
if [ "$platform" = "AWS" ]; then
    mkdir -p $HOME/.aws
    cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
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

    AZURE_TENANT_ID="$(jq -r .tenantId ${AZURE_AUTH_LOCATION})"

    AZURE_CLIENT_ID="$(jq -r .clientId ${AZURE_AUTH_LOCATION})"
    
    AZURE_CLIENT_SECRET="$(jq -r .clientSecret ${AZURE_AUTH_LOCATION})"

elif [ "$platform" = "IBMCloud" ]; then
# https://github.com/openshift/release/blob/3afc9cb376776ca27fbb1a4927281e84295f4810/ci-operator/step-registry/openshift-extended/upgrade/pre/openshift-extended-upgrade-pre-commands.sh#L158
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output   
    region="${LEASED_RESOURCE}"
    export CLOUD_TYPE="ibmcloud"
    export region
    export IBMC_URL="https://${region}.iaas.cloud.ibm.com/v1"
    export IBMC_APIKEY=${CLUSTER_PROFILE_DIR}/ibmcloud-api-key
fi 
ls -al /secret/telemetry/

ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ELASTIC_INDEX=krkn_chaos_ci

# read passwords from vault
telemetry_password=$(cat "/secret/telemetry/telemetry_password")

# set the secrets from the vault as env vars
export TELEMETRY_PASSWORD=$telemetry_password


./power-outage/prow_run.sh
rc=$?
echo "Finished running power outages"
echo "Return code: $rc"
