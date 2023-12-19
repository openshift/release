#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
API_PUBLISH_STRATEGY=$(yq-go r "${INSTALL_CONFIG}" 'operatorPublishingStrategy.apiserver')
INGRESS_PUBLISH_STRATEGY=$(yq-go r "${INSTALL_CONFIG}" 'operatorPublishingStrategy.ingress')
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
BASE_DOMAIN=$(yq-go r "${INSTALL_CONFIG}" 'baseDomain')
BASE_DOMAIN_RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.baseDomainResourceGroupName')
CLUSTER_NAME=$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

PUBLIC_LB_NAME="${INFRA_ID}"
INTERNAL_LB_NAME="${INFRA_ID}-internal"
API_SERVER_PORT="6443"
INGRESS_PORTS="80 443"
API_DNS_NAME="api.${CLUSTER_NAME}"
INGRESS_DNS_NAME="*.apps.${CLUSTER_NAME}"

check_result=0
#save lb info
echo "lb rules on public loadbalancer: "
public_lb_rules=$(mktemp)
az network lb rule list --lb-name ${PUBLIC_LB_NAME} -g ${RESOURCE_GROUP} | tee ${public_lb_rules}

echo -e "\nlb rules on internal loadbalancer: "
internal_lb_rules=$(mktemp)
az network lb rule list --lb-name ${INTERNAL_LB_NAME} -g ${RESOURCE_GROUP} | tee ${internal_lb_rules}

if [[ "${API_PUBLISH_STRATEGY}" == "Internal" ]]; then
    # Load Balance Rules on port 6443 should only be created in internal LB
    # outbound rule and associated public IP are created in public LB
    # API dns record is not created in public zone 

    echo "API_PUBLISH_STRATEGY: ${API_PUBLISH_STRATEGY}, checking resources in lb and dns zone"
    echo "(*) check that LB rule on port ${API_SERVER_PORT} is not created in public LB..."
    api_pubilc_lb_rule=$(cat ${public_lb_rules} | jq -r ".[] | select(.backendPort==${API_SERVER_PORT})")
    if [[ ! -z "${api_pubilc_lb_rule}" ]]; then
        echo "ERROR: found lb rule on port ${API_SERVER_PORT} in public LB!"
        check_result=1
    fi

    echo "(*) check that LB rule on port ${API_SERVER_PORT} is created in internal LB..."
    api_internal_lb_rule_id=$(cat ${internal_lb_rules} | jq -r ".[] | select(.backendPort==${API_SERVER_PORT}) | .id")
    if [[ -z "${api_internal_lb_rule_id}" ]]; then
        echo "ERROR: not found lb rule on port ${API_SERVER_PORT} in internal LB!"
        check_result=1
    else
        echo "(*) check private ip address is configured as frontendIP for lb rule on port ${API_SERVER_PORT} in internal lb ${INTERNAL_LB_NAME}"
        lb_private_ip=""
        lb_private_ip=$(az network lb show -g ${RESOURCE_GROUP} -n ${INTERNAL_LB_NAME} | jq -r ".frontendIPConfigurations[] | select(.loadBalancingRules) | select(.loadBalancingRules[].id==\"${api_internal_lb_rule_id}\") | .privateIPAddress")
        if [[ -z ${lb_private_ip} ]] || [[ "${lb_private_ip}" == "null" ]]; then
            echo "ERROR: not found private ip address for load balancer rule ${api_internal_lb_rule_id} in internal lb ${INTERNAL_LB_NAME}"
            check_result=1
        fi
    fi

    echo "(*) check that outbound rule is created in public lb..."
    outbound_rules_id=$(az network lb show --name ${PUBLIC_LB_NAME} -g ${RESOURCE_GROUP} -ojson | jq -r ".outboundRules[].id")
    if [[ -z "${outbound_rules_id}" ]]; then
        echo "ERROR: Not found outbound rules for public load balancer ${PUBLIC_LB_NAME}!"
        check_result=1
    else
        echo "(*) check that public ip address is configured as frontendIP for outbound rule in public lb..."
        lb_public_ip_id=""
        lb_public_ip_id=$(az network lb show -g ${RESOURCE_GROUP} -n ${PUBLIC_LB_NAME} | jq -r ".frontendIPConfigurations[] | select(.outboundRules) | select(.outboundRules[].id==\"${outbound_rules_id}\")| .publicIPAddress.id")
        if [[ -z ${lb_public_ip_id} ]] || [[ "${lb_public_ip_id}" == "null" ]]; then
            echo "ERROR: not found public ip address for outbound rule ${outbound_rules_id} in public lb ${PUBLIC_LB_NAME}!"
            check_result=1
        fi
    fi

    echo "(*) check that api dns record is not created in public zone..."
    ret=0
    az network dns record-set cname show --name ${API_DNS_NAME} --resource-group ${BASE_DOMAIN_RESOURCE_GROUP} --zone-name ${BASE_DOMAIN} || ret=1
    if (( ret == 0 )); then
        echo "ERROR: found api dns in public zone!"
        check_result=1
    fi

else
    # API_PUBLISH_STRATEGY should be External or ""
    # Load Balance Rules on port 6443 should be created in both public LB and internal LB
    # public IP associated with lb rules on port 6443 is created in public LB
    # API dns reocrds is created in public zone

    echo "API_PUBLISH_STRATEGY: ${API_PUBLISH_STRATEGY}, checking resources in lb and dns zone"
    echo "(*) check that LB rule on port ${API_SERVER_PORT} is created in public LB..."
    api_pubilc_lb_rule_id=$(cat ${public_lb_rules} | jq -r ".[] | select(.backendPort==${API_SERVER_PORT}) | .id")
    if [[ -z "${api_pubilc_lb_rule_id}" ]]; then
        echo "ERROR: not found lb rule on port ${API_SERVER_PORT} in public LB!"
        check_result=1
    else
        echo "(*) check public ip address is configured as frontendIP for lb rule on port ${API_SERVER_PORT} in public lb ${PUBLIC_LB_NAME}"
        lb_public_ip=""
        lb_public_ip=$(az network lb show -g ${RESOURCE_GROUP} -n ${PUBLIC_LB_NAME} | jq -r ".frontendIPConfigurations[] | select(.loadBalancingRules) | select(.loadBalancingRules[].id==\"${api_pubilc_lb_rule_id}\") | .publicIPAddress.id")
        if [[ -z ${lb_public_ip} ]] || [[ "${lb_public_ip}" == "null" ]]; then
            echo "ERROR: not found public ip address for load balancer rule ${api_pubilc_lb_rule_id} in public lb ${PUBLIC_LB_NAME}"
            check_result=1
        fi
    fi

    echo "(*) check that LB rule on port ${API_SERVER_PORT} is created in internal LB..."
    api_internal_lb_rule=$(cat ${internal_lb_rules} | jq -r ".[] | select(.backendPort==${API_SERVER_PORT})")
    if [[ -z "${api_internal_lb_rule}" ]]; then
        echo "ERROR: not found lb rule on port ${API_SERVER_PORT} in internal LB!"
        check_result=1
    fi

    echo "(*) check that api dns record is created in public zone..."
    ret=0
    az network dns record-set cname show --name ${API_DNS_NAME} --resource-group ${BASE_DOMAIN_RESOURCE_GROUP} --zone-name ${BASE_DOMAIN} || ret=1
    if (( ret == 1 )); then
        echo "ERROR: not found api dns in public zone!"
        check_result=1
    fi
fi

if [[ "${INGRESS_PUBLISH_STRATEGY}" == "Internal" ]]; then
    # Load Balance Rules on port 80|443 should be created in internal LB
    # *.apps dns record is not created in public zone

    echo "INGRESS_PUBLISH_STRATEGY: ${INGRESS_PUBLISH_STRATEGY}, checking resources in lb and dns zone"
    echo "(*) check that LB rules on ports ${INGRESS_PORTS} are created in internal LB..."
    for port in ${INGRESS_PORTS}; do
        echo "checking on ${port}"
        ingress_lb_rule_id=$(cat ${internal_lb_rules} | jq -r ".[] | select(.backendPort==${port}) | .id")
        if [[ -z "${ingress_lb_rule_id}" ]]; then
            echo "ERROR: not found lb rule on port ${port} in internal LB!"
            check_result=1
        else
            echo "---- check private ip is configured as frontendIP for lb rules on port ${port} in internal LB ${INTERNAL_LB_NAME}"
            lb_private_ip=""
            lb_private_ip=$(az network lb show -g ${RESOURCE_GROUP} -n ${INTERNAL_LB_NAME} | jq -r ".frontendIPConfigurations[] | select(.loadBalancingRules) | select(.loadBalancingRules[].id==\"${ingress_lb_rule_id}\") | .privateIPAddress")
            if [[ -z "${lb_private_ip}" ]] || [[ "${lb_private_ip}" == "null" ]]; then
                echo "ERROR: not found priavte ip address for load balancer rule ${ingress_lb_rule_id} in internal lb ${INTERNAL_LB_NAME}"
                check_result=1
            fi
        fi
    done

    echo "(*) check that *.apps dns record is not created in public zone..."
    ret=0
    az network dns record-set a show --name ${INGRESS_DNS_NAME} --resource-group ${BASE_DOMAIN_RESOURCE_GROUP} --zone-name ${BASE_DOMAIN} || ret=1
    if (( ret == 0 )); then
        echo "ERROR: found *.apps dns in public zone!\n${ret}"
        check_result=1
    fi
else
    # API_PUBLISH_STRATEGY should be External or ""
    # Load Balance Rules on port 80|443 and associated public IP should be created in Public LB
    # *.apps dns record is created in public zone

    echo "INGRESS_PUBLISH_STRATEGY: ${INGRESS_PUBLISH_STRATEGY}, checking resources in lb and dns zone"
    echo "(*) check that LB rules on ports ${INGRESS_PORTS} are created in public LB..."
    for port in ${INGRESS_PORTS}; do
        echo "checking on ${port}"
        echo "---- check lb rules on ${port}"
        ingress_lb_rule_id=$(cat ${public_lb_rules} | jq -r ".[] | select(.backendPort==${port}) | .id")
        if [[ -z "${ingress_lb_rule_id}" ]]; then
            echo "ERROR: not found lb rule on port ${port} in public LB!"
            check_result=1
        else
            echo "---- check public ip is configured as frontendIP for lb rules on port ${port} in public LB ${PUBLIC_LB_NAME}"
            lb_public_ip=""
            lb_public_ip=$(az network lb show -g ${RESOURCE_GROUP} -n ${PUBLIC_LB_NAME} | jq -r ".frontendIPConfigurations[] | select(.loadBalancingRules) | select(.loadBalancingRules[].id==\"${ingress_lb_rule_id}\") | .publicIPAddress.id")
            if [[ -z ${lb_public_ip} ]] || [[ "${lb_public_ip}" == "null" ]]; then
                echo "ERROR: not found public ip address for load balancer rule ${ingress_lb_rule_id} in public lb ${PUBLIC_LB_NAME}"
                check_result=1
            fi
        fi
    done

    echo "(*) check that *.apps dns record is created in public zone..."
    ret=0
    az network dns record-set a show --name ${INGRESS_DNS_NAME} --resource-group ${BASE_DOMAIN_RESOURCE_GROUP} --zone-name ${BASE_DOMAIN} || ret=1
    if (( ret == 1 )); then
        echo "ERROR: not found *.apps dns in public zone!"
        check_result=1
    fi
fi
exit ${check_result}
