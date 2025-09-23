#!/bin/bash

set -o nounset

export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

echo "$(date -u --rfc-3339=seconds) - Installing tools..."

# install jq
# TODO move to image
curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/bin/jq
chmod ug+x /tmp/bin/jq

# install newest oc
curl -L --fail https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar xvzf - -C /tmp/bin/ oc
chmod ug+x /tmp/bin/oc

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .tenantId)"

CLUSTER_NAME="$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)"
echo "Cluster name: $CLUSTER_NAME"
CLUSTER_VERSION="$(/tmp/bin/oc adm release info -o json | jq -r .metadata.version)"
echo "Cluster version: $CLUSTER_VERSION"
RESOURCE_GROUP="$(oc get -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' infrastructure cluster)"
echo "Resource group: $RESOURCE_GROUP"
SUBSCRIPTION_ID="$(oc get configmap -n openshift-config cloud-provider-config -o jsonpath='{.data.config}' | jq -r '.subscriptionId')"
echo "Subscription ID: $SUBSCRIPTION_ID"

echo "$(date -u --rfc-3339=seconds) - Logging in to Azure..."
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}"

echo "$(date -u --rfc-3339=seconds) - Listing load balancer resources"
LB_RESOURCES="$(az resource list --resource-type Microsoft.Network/loadBalancers --resource-group $RESOURCE_GROUP --subscription $SUBSCRIPTION_ID | jq -r '.[].id')"

OUTPUT_DIR="${ARTIFACT_DIR}/azure-monitor-metrics/"
mkdir -p "$OUTPUT_DIR"

for i in $LB_RESOURCES; do
    echo "$i"
    LB_NAME="$(basename $i)" # Grabs the last token of the resource id, which is it's friendly name.
    echo "$LB_NAME"
    metrics=( SnatConnectionCount AllocatedSnatPorts UsedSnatPorts PacketCount ByteCount )
    for m in "${metrics[@]}";
    do
        echo "$(date -u --rfc-3339=seconds) - Gathering metric $m for load balancer $i"
        az monitor metrics list --resource $i --offset 3h --metrics $m --subscription $SUBSCRIPTION_ID > $OUTPUT_DIR/lb-$LB_NAME-$m.json
    done
    # One-off additional filter for failed connections:
    az monitor metrics list --resource $i --offset 3h --metrics SnatConnectionCount --filter "ConnectionState eq 'Failed'"  --subscription $SUBSCRIPTION_ID > $OUTPUT_DIR/lb-$LB_NAME-SnatConnectionCount-ConnectionFailed.json
done

echo "$(date -u --rfc-3339=seconds) - Gathering load balancer resources complete"

# Gather Azure console logs.
echo "$(date -u --rfc-3339=seconds) - Gathering console logs"

if test -f "${KUBECONFIG}"
then
  TMPDIR=/tmp/azure-boot-logs
  mkdir -p $TMPDIR
  oc --request-timeout=5s -n openshift-machine-api get machines -o jsonpath --template '{range .items[*]}{.metadata.name}{"\n"}{end}' >> "${TMPDIR}/azure-instance-names.txt"
  RESOURCE_GROUP="$(oc get -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' infrastructure cluster)"
else
  echo "No kubeconfig; skipping boot log extraction."
  exit 0
fi

az version

EXIT_CODE=0
# This allows us to continue and try to gather other boot logs.
set +o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Gathering disk metrics"
for VM_NAME in $(sort < "${TMPDIR}/azure-instance-names.txt" | uniq)
do
  metrics=( "OS Disk Queue Depth" "OS Disk Write Bytes/Sec" )
  for m in "${metrics[@]}";
  do
    echo "$(date -u --rfc-3339=seconds) - Gathering metric $m for VM ${VM_NAME}"
    az monitor metrics list --resource-type "Microsoft.Compute/virtualMachines" --resource ${VM_NAME} --resource-group "${RESOURCE_GROUP}" --offset 3h --metrics "$m" --subscription $SUBSCRIPTION_ID > $OUTPUT_DIR/disk-$VM_NAME-${m//[^[:alnum:]]/""}.json
  done
done
echo "$(date -u --rfc-3339=seconds) - Gathering disk metrics complete"

for VM_NAME in $(sort < "${TMPDIR}/azure-instance-names.txt" | uniq)
do
  echo "Gathering console logs for ${VM_NAME} in resource group ${RESOURCE_GROUP}"
  # The echo wrapping causes the raw newlines and ANSI control sequences
  # returned by `az` to be rendered, producing a more readable log.
  # shellcheck disable=SC2116,SC2046
  if ! LC_ALL=en_US.UTF-8 echo $(az vm boot-diagnostics get-boot-log --name "${VM_NAME}" --resource-group "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION_ID}") > "${ARTIFACT_DIR}/${VM_NAME}-boot.log"
  then
    EXIT_CODE="${?}"
  fi
done

echo "$(date -u --rfc-3339=seconds) - Gathering console logs complete"

exit "${EXIT_CODE}"
