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
echo "starting master node disruption scenario"

platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}') 
if [ "$platform" = "AWS" ]; then
    mkdir -p $HOME/.aws
    cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
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
    NODE_NAME=$(oc get nodes -l $LABEL_SELECTOR --no-headers | head -1 | awk '{printf $1}' )
    export NODE_NAME
    export TIMEOUT=320
elif [ "$platform" = "VSphere" ]; then
    export CLOUD_TYPE="vsphere"
    VSPHERE_IP=$(oc get infrastructures.config.openshift.io cluster -o jsonpath='{.spec.platformSpec.vsphere.vcenters[0].server}')
    export VSPHERE_IP
    VSPHERE_IP_WITHOUTDOT=$(echo "$VSPHERE_IP" | sed 's/\./\\./g')
    jsonpath_username="{.data.${VSPHERE_IP_WITHOUTDOT}\.username}"
    jsonpath_password="{.data.${VSPHERE_IP_WITHOUTDOT}\.password}"
    VSPHERE_USERNAME=$(oc get secret vsphere-creds -n kube-system -o jsonpath="$jsonpath_username" | base64 --decode)
    export VSPHERE_USERNAME
    VSPHERE_PASSWORD=$(oc get secret vsphere-creds -n kube-system -o jsonpath="$jsonpath_password" | base64 --decode)
    export VSPHERE_PASSWORD
fi

./node-disruptions/prow_run.sh
rc=$?

if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi

echo "Finished running master node disruption observer"
echo "Return code: $rc"
exit $rc 