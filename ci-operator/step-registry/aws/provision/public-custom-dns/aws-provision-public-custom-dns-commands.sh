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

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

# cluster info
if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then source "${SHARED_DIR}/proxy-conf.sh"; fi

ingress_lb_hostname=$(oc -n openshift-ingress get service router-default -o json | jq -r '.status.loadBalancer.ingress[].hostname')

if [ -f "${SHARED_DIR}/unset-proxy.sh" ]; then source "${SHARED_DIR}/unset-proxy.sh"; fi

# External API
api_lb_ext_name=${INFRA_ID}-ext
api_lb_ext_out=${ARTIFACT_DIR}/api_lb_ext_out.json
aws --region ${REGION} elbv2 describe-load-balancers --names ${api_lb_ext_name} > ${api_lb_ext_out}

# Internal API
api_lb_int_name=${INFRA_ID}-int
api_lb_int_out=${ARTIFACT_DIR}/api_lb_int_out.json
api_lb_int_network_interface_out=${ARTIFACT_DIR}/api_lb_int_network_interface_out.json

aws --region ${REGION} elbv2 describe-load-balancers --names ${api_lb_int_name} > ${api_lb_int_out}
api_lb_int_arn=$(jq -r '.LoadBalancers[].LoadBalancerArn' ${api_lb_int_out})
api_lb_int_filter_desc="ELB $(echo $api_lb_int_arn | awk -F'/' '{print $2,$3,$4}' | sed 's/ /\//g')"
aws --region ${REGION} ec2 describe-network-interfaces --filters Name=description,Values="$api_lb_int_filter_desc" > ${api_lb_int_network_interface_out}

# ingress
ingress_lb_network_interface_out=${ARTIFACT_DIR}/ingress_lb_network_interface_out.json
ingress_lb_name=$(aws --region ${REGION} elb describe-load-balancers | jq -r --arg dnsname ${ingress_lb_hostname} '.LoadBalancerDescriptions[] | select(.DNSName == $dnsname).LoadBalancerName')
ingress_lb_filter_desc="ELB ${ingress_lb_name}"
aws --region ${REGION} ec2 describe-network-interfaces --filters Name=description,Values="$ingress_lb_filter_desc" > ${ingress_lb_network_interface_out}

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
 
public_custom_dns_json=${SHARED_DIR}/public_custom_dns.json

api_lb_ext_dns_name=$(jq -r '.LoadBalancers[].DNSName' ${api_lb_ext_out})
add_lb_record "api.${CLUSTER_NAME}.${BASE_DOMAIN}." "${api_lb_ext_dns_name}." "CNAME" ${public_custom_dns_json}
add_lb_record "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." "${ingress_lb_hostname}." "CNAME" ${public_custom_dns_json}

echo "public_custom_dns.json:"
cat $public_custom_dns_json | jq

# -------------------------------------------
# For the bastion which acts a DNS server.
# -------------------------------------------
# Resolve External API -> Private IPs
for ip in $(jq -r '.NetworkInterfaces[].PrivateIpAddress' ${api_lb_int_network_interface_out});
do
    echo "api.${CLUSTER_NAME}.${BASE_DOMAIN} ${ip}" >> "${SHARED_DIR}/custom_dns"
done

# TODO: Ingress LB -> Private IPs
for ip in $(jq -r '.NetworkInterfaces[].PrivateIpAddress' ${ingress_lb_network_interface_out});
do
    echo "apps.${CLUSTER_NAME}.${BASE_DOMAIN} ${ip}" >> "${SHARED_DIR}/custom_dns"
done

echo "custom_dns:"
cat ${SHARED_DIR}/custom_dns
