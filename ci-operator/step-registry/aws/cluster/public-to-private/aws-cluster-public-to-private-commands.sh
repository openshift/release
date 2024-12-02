#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

if (( ocp_minor_version <= 11&& ocp_major_version == 4 )); then
  echo "CPMS support for AWS was added in 4.12, the following step is not applicable for this OCP version, quit now."
  exit 1
fi

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "ERROR: fail to get the kubeconfig file under ${SHARED_DIR}!!"
    exit 1
fi

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
    echo ""
}

function check_cpms_status() {
    local DesiredCount COUNTER readyCPMSCount updatedCPMSCount
    DesiredCount=$(oc get controlplanemachineset/cluster -n openshift-machine-api -o=jsonpath='{.spec.replicas}')
    COUNTER=0
    #The rolling update and re-creation of the three masters will take about 1 hour
    while [ $COUNTER -lt 4500 ]
    do
        sleep 300
        COUNTER=`expr $COUNTER + 300`
        echo "waiting ${COUNTER}s"
	#During master rolling update, the API server may not response
	readyCPMSCount=$(oc get controlplanemachineset/cluster -n openshift-machine-api -o=jsonpath='{.status.readyReplicas}' || true)
	updatedCPMSCount=$(oc get controlplanemachineset/cluster -n openshift-machine-api -o=jsonpath='{.status.updatedReplicas}' || true)
        if [[ ${readyCPMSCount} == "${DesiredCount}" ]] && [[ ${updatedCPMSCount} == "${DesiredCount}" ]]; then
            echo "CPMS update finished."
            break
        fi
    done
    if [[ ${readyCPMSCount} != "${DesiredCount}" ]] || [[ ${updatedCPMSCount} != "${DesiredCount}" ]]; then
	echo "Something wrong in the CPMS update:"
        run_command "oc get machines -n openshift-machine-api"
        run_command "oc get controlplanemachineset/cluster -n openshift-machine-api -o yaml"
        return 1
    fi
}


#Setting the Ingress Controller to private
echo "Configuring DNS records to be published in the private zone"
run_command "oc patch dnses.config.openshift.io/cluster --type=merge --patch='{\"spec\": {\"publicZone\": null}}'"

echo "Setting the Ingress Controller to private"
oc replace --force --wait --filename - <<EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  namespace: openshift-ingress-operator
  name: default
spec:
  endpointPublishingStrategy:
    type: LoadBalancerService
    loadBalancer:
      scope: Internal
EOF


# Remove the external load balancers from CPMS
CPMS_PATCH=$(mktemp)
cat >"${CPMS_PATCH}" <<EOF
spec:
  template:
    machines_v1beta1_machine_openshift_io:
      spec:
        providerSpec:
          value:
            loadBalancers:
            - name: ${INFRA_ID}-int
              type: network
EOF

echo "Remove the external load balancers from CPMS"
run_command "oc patch controlplanemachineset/cluster -n openshift-machine-api --type merge --patch-file ${CPMS_PATCH}"

#Wait for CPMS update finished
#masters was removed from the external LB, need to export proxy to access the cluster
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
else
  echo "No proxy-conf found, exit now"
  exit 1
fi

check_cpms_status


#Restricting the API server to private by removing the external LB
EXT_LB_ARN=$(aws --region ${REGION} elbv2 describe-load-balancers |jq --arg var "${INFRA_ID}" -r '.LoadBalancers[] | select(.LoadBalancerName == "\($var)-ext") | .LoadBalancerArn')

if [[ -z ${EXT_LB_ARN} ]]; then
  echo "Error: Fail to get the external LB ARN, exit"
  exit 1
fi

echo "Delete the external load balancer"
run_command "aws --region ${REGION} elbv2 delete-load-balancer --load-balancer-arn ${EXT_LB_ARN}"


#Delete the API DNS entry in the public zone
if [[ -z ${BASE_DOMAIN} ]]; then
  echo "Error: BASE_DOMAIN is not set"
  exit 1
fi

PUBLIC_ZONE_ID=$(aws route53 list-hosted-zones-by-name | jq --arg name "${BASE_DOMAIN}." -r '.HostedZones | .[] | select(.Name=="\($name)") | .Id' | awk -F / '{printf $3}')
RECORD_SETS=$(aws route53 list-resource-record-sets --hosted-zone-id=${PUBLIC_ZONE_ID} --output json | jq --arg dns "api.${CLUSTER_NAME}.${BASE_DOMAIN}." '.ResourceRecordSets[] | select(.Name == "\($dns)")')

if [[ -z ${RECORD_SETS} ]]; then
  echo "Error: Fail to get the API DNS record, exit"
  exit 1
fi

ROUTE53_CHANGE_BATCH=$(mktemp)
cat >"${ROUTE53_CHANGE_BATCH}" << EOF
{
    "Comment": "Delete the cluster public API record",
    "Changes": [
        {
            "Action": "DELETE",
            "ResourceRecordSet":
              ${RECORD_SETS}
        }
    ]
}
EOF

CHANG_BATCH_REQUEST=$(mktemp)
echo "Delete the API DNS entry in the public zone"
run_command "aws route53 change-resource-record-sets --hosted-zone-id=${PUBLIC_ZONE_ID} --change-batch file://${ROUTE53_CHANGE_BATCH} | tee ${CHANG_BATCH_REQUEST}"
BATCH_REQUEST_ID=$(cat "$CHANG_BATCH_REQUEST" |jq -r .ChangeInfo.Id)
run_command "aws route53 wait resource-record-sets-changed --id $BATCH_REQUEST_ID"
