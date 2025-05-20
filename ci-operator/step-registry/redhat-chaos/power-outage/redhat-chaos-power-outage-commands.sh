#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config
export KRKN_KUBE_CONFIG=$KUBECONFIG



platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}') 
if [ "$platform" = "AWS" ]; then
    mkdir -p $HOME/.aws
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
    aws_region=${REGION:-$LEASED_RESOURCE}
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
    region="${LEASED_RESOURCE}"
    CLOUD_TYPE="ibmcloud"
    export CLOUD_TYPE
    export region
    IBMC_URL="https://${region}.iaas.cloud.ibm.com/v1"
    export IBMC_URL
    IBMC_APIKEY=$(cat ${CLUSTER_PROFILE_DIR}/ibmcloud-api-key)
    export IBMC_APIKEY

    export TIMEOUT=320

fi

ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")

export ES_PASSWORD
export ES_USERNAME

export ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

# read passwords from vault
telemetry_password=$(cat "/secret/telemetry/telemetry_password")

# set the secrets from the vault as env vars
export TELEMETRY_PASSWORD=$telemetry_password


./power-outage/prow_run.sh
rc=$?
if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi
echo "Finished running power outages"
echo "Return code: $rc"
