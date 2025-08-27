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

function add_lb_record() {
    local name="$1"
    local target="$2"
    local record_type="$3"
    local out="$4"
    if [ ! -e "$out" ]; then
        echo -n '[]' > "$out"
    fi
    cat <<< "$(jq --arg n "${name}" --arg t "${target}" --arg r "${record_type}" '. += [{"name": $n, "target": $t, "record_type": $r}]' "$out")" > "$out"
}

function get_ingress()
{
    local lb_out=$1
    local network_out=$2
    local lb_arn lb_name desc

    lb_arn=$(aws --region ${REGION} resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer --tag-filters Key=kubernetes.io/cluster/${INFRA_ID},Values=owned Key=kubernetes.io/service-name,Values=openshift-ingress/router-default --query "ResourceTagMappingList[*].ResourceARN" | jq -r '.[0] // ""')
    if [ ${lb_arn} == "" ]; then
        echo "Error: Ingress LB with kubernetes.io/cluster/${INFRA_ID}:owned tag can not be found."
        return 1
    fi

    lb_name=$(echo ${lb_arn} | awk -F'/' '{print $2}')
    desc="ELB ${lb_name}"

    aws --region ${REGION} elb describe-load-balancers --load-balancer-names ${lb_name} > ${lb_out}
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

# api ext
API_EXT_LB_OUT=${ARTIFACT_DIR}/api_int.json
API_EXT_NETWORK_OUT=${ARTIFACT_DIR}/api_int_network.json
get_api_lb "ext" "${API_EXT_LB_OUT}" "${API_EXT_NETWORK_OUT}"

# The following records will be added to the external DNS
# example output:
# [
#   {
#     "name": "api.cluster1.devclusters.example.com.",
#     "target": "yunjiang-0607-wh89d-ext-768f8fa77ffcbb95.elb.us-east-2.amazonaws.com.",
#     "record_type": "CNAME"
#   },
#   {
#     "name": "*.apps.cluster1.devclusters.example.com.",
#     "target": "a8dd5ee03656b4e32809109eb1f33eff-2039818201.us-east-2.elb.amazonaws.com.",
#     "record_type": "CNAME"
#   }
# ]

add_lb_record "api.${CLUSTER_NAME}.${BASE_DOMAIN}." "$(jq -r '.LoadBalancers[].DNSName' ${API_EXT_LB_OUT})." "CNAME" ${SHARED_DIR}/public_custom_dns.json
add_lb_record "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." "$(jq -r '.LoadBalancerDescriptions[].DNSName' ${INGRESS_LB_OUT})." "CNAME" ${SHARED_DIR}/public_custom_dns.json

echo "public_custom_dns.json:"
jq . ${SHARED_DIR}/public_custom_dns.json
