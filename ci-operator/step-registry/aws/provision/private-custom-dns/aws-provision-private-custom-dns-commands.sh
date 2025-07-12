#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

function get_ingress()
{
    local lb_out=$1
    local network_out=$2
    local i lb_name desc
    i=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-worker*" | jq -r '.Reservations[0].Instances[0].InstanceId')
    aws --region $REGION elb describe-load-balancers --query "LoadBalancerDescriptions[?Instances[?InstanceId=='${i}']]" > ${lb_out}
    lb_name=$(jq -r '.[].LoadBalancerName' ${lb_out})
    desc="ELB ${lb_name}"
    aws --region ${REGION} ec2 describe-network-interfaces --filters Name=description,Values="$desc" > ${network_out}
}

function get_api_lb()
{
    local int_or_ext=$1
    local lb_out=$2
    local network_out=$3
    local arn desc
    aws --region ${REGION} elbv2 describe-load-balancers --names ${INFRA_ID}-${int_or_ext} > ${lb_out}

    arn=$(jq -r '.LoadBalancers[].LoadBalancerArn' ${lb_out})
    desc="ELB $(echo $arn | awk -F'/' '{print $2,$3,$4}' | sed 's/ /\//g')"
    aws --region ${REGION} ec2 describe-network-interfaces --filters Name=description,Values="$desc" > ${network_out}
}

# ingress
INGRESS_LB_OUT=${ARTIFACT_DIR}/ingress.json
INGRESS_NETWORK_OUT=${ARTIFACT_DIR}/ingress_network.json
get_ingress "${INGRESS_LB_OUT}" "${INGRESS_NETWORK_OUT}"

# api-int
API_INT_LB_OUT=${ARTIFACT_DIR}/api_int.json
API_INT_NETWORK_OUT=${ARTIFACT_DIR}/api_int_network.json
get_api_lb "int" "${API_INT_LB_OUT}" "${API_INT_NETWORK_OUT}"


# -------------------------------------------
# dnsmasq configuration
# -------------------------------------------
# Resolve Internal API -> Private IPs
for ip in $(jq -r '.NetworkInterfaces[].PrivateIpAddress' ${API_INT_NETWORK_OUT});
do
    echo "api.${CLUSTER_NAME}.${BASE_DOMAIN} ${ip}" >> "${SHARED_DIR}/custom_dns"
done

# Resolve Ingress LB -> Private IPs
for ip in $(jq -r '.NetworkInterfaces[].PrivateIpAddress' ${INGRESS_NETWORK_OUT});
do
    echo "apps.${CLUSTER_NAME}.${BASE_DOMAIN} ${ip}" >> "${SHARED_DIR}/custom_dns"
done

echo "custom_dns:"
cat ${SHARED_DIR}/custom_dns
