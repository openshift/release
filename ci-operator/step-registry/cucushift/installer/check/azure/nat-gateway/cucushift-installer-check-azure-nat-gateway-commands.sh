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

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

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
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID "${SHARED_DIR}"/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi
REGION="$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.region')"
OUTBOUND_TYPE="$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.outboundType')"
OUTBOUND_TYPE=${OUTBOUND_TYPE:-Loadbalancer}
NETWORK_RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.networkResourceGroupName')
NETWORK_RESOURCE_GROUP="${NETWORK_RESOURCE_GROUP:-$RESOURCE_GROUP}"
subnets_json_array=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.subnets' -j)

if [[ -z "${subnets_json_array}" ]]; then
    # No byo subnets, installer creates them
    subnets_json_array="[{\"name\": \"${INFRA_ID}-master-subnet\",\"role\": \"control-plane\"},{\"name\": \"${INFRA_ID}-worker-subnet\",\"role\": \"node\"}]"
    if [[ "${OUTBOUND_TYPE}" == "NATGatewayMultiZone" ]]; then
        region_display_name="$(az account list-locations --query "[?name=='${REGION}'].displayName" --output tsv)"
        zone_number="$(az provider show --namespace Microsoft.Network --query "resourceTypes[?resourceType=='natGateways'].zoneMappings[] | [?location=='${region_display_name}'].zones | [0]" --output tsv | wc -l)"
        if (( ${zone_number} > 1 )); then
            additonal_node_subnets=""
            for (( num=2; num<=${zone_number}; num++ )); do
                if [[ -n "${additonal_node_subnets}" ]]; then
                    additonal_node_subnets="${additonal_node_subnets},"
                fi
                additonal_node_subnets="${additonal_node_subnets}{\"name\": \"${INFRA_ID}-worker-subnet-${num}\",\"role\": \"node\"}"
            done
            additonal_node_subnets="[${additonal_node_subnets}]"
            subnets_json_array=$(echo "${subnets_json_array}" | jq --argjson second_array "${additonal_node_subnets}" '. + $second_array')
        else
            echo "Region ${REGION} does not support available zone, while OUTBOUND_TYPE is NATGatewayMultiZone, installer should exit with error..., exit!"
            exit 1
        fi
    fi
fi

echo "INFRA_ID: ${INFRA_ID}"
echo "OUTBOUND_TYPE: ${OUTBOUND_TYPE}"
echo "NETWORK_RESOURCE_GROUP: ${NETWORK_RESOURCE_GROUP}"
echo "SUBNETS: ${subnets_json_array}"

check_result=0
if [[ "${OUTBOUND_TYPE}" != "Loadbalancer" ]]; then
    echo "check that nat gateways attach to node subnets..."
    natgateway_json_array=$(az network nat gateway list -g ${RESOURCE_GROUP} | jq '[.[] | {name: .name, subnets: .subnets, zones: .zones}]')

    if [[ "${OUTBOUND_TYPE}" == "NATGatewaySingleZone" ]] || [[ "${OUTBOUND_TYPE}" == "NATGateway" ]]; then
        nat_gateway_id=$(echo "${natgateway_json_array}" | jq -r '.[].subnets[].id')
        echo "${subnets_json_array}" | jq -c '.[]' | while IFS= read -r item; do
            subnet_name=$(echo "${item}" | jq -r '.name')
            subnet_role=$(echo "${item}" | jq -r '.role')
            if [[ "${subnet_role}" == "control-plane" ]] && (( ocp_minor_version >= 20 )); then
                echo "INFO: starting from 4.20, NAT gateways only attach on worker subnets, skip checking on master subnet!"
                continue
            fi
            if [[ "${subnet_name}" == "${nat_gateway_id##*/}" ]]; then
                echo "INFO: ${subnet_name} check pass!"
            else
                echo "ERROR: ${subnet_name} check fail! nat gateway id: ${nat_gateway_id}!"
                check_result=1
            fi
        done
    elif [[ "${OUTBOUND_TYPE}" == "NATGatewayMultiZone" ]]; then
        subnets_json_file=$(mktemp)
        echo "${subnets_json_array}" > ${subnets_json_file}
        echo "${subnets_json_array}" | jq -c '.[]' | while IFS= read -r item; do
            subnet_name=$(echo "${item}" | jq -r '.name')
            subnet_role=$(echo "${item}" | jq -r '.role')

            if [[ "${subnet_role}" == "control-plane" ]]; then
                echo "INFO: NAT gateways only attach on worker subnets, skip checking on master subnet!"
                continue
            fi

            match_count=$(echo "${natgateway_json_array}" | jq --arg name "${subnet_name}" '[.[] | select(.subnets[].id | endswith($name))] | length') 
            if [[ ${match_count} -gt 0 ]]; then
                echo "INFO: ${subnet_role} ${subnet_name} check pass!"
                # insert zone of natgateway associated subnet {subnet_name} into subnets_json_array, for compute machineset check
                natgateway_zone="$(echo "${natgateway_json_array}" | jq -r --arg name "${subnet_name}" '.[] | select(.subnets[].id | endswith($name)) | .zones[]')"
                jq --arg name "${subnet_name}" --arg value "${natgateway_zone}" 'map(if .name == $name then . + {"zone": $value} else . end)' ${subnets_json_file} > "${subnets_json_file}.tmp"
                mv "${subnets_json_file}.tmp" "${subnets_json_file}"
            else
                echo "ERROR: ${subnet_role} ${subnet_name} check failed! natgateway list: ${natgateway_json_array}"
                check_result=1
            fi

        done
        subnets_json_array="$(< ${subnets_json_file})"
        rm ${subnets_json_file}
    else
        echo "Unsupported outbound type: ${OUTBOUND_TYPE}"
        exit 1
    fi
fi

#cpms check
echo "CPMS checking..."
master_sunbet_name=$(echo "${subnets_json_array}" | jq -r '.[] | select(.role == "control-plane") | .name')
cpms_subnet=$(oc get controlplanemachineset.machine.openshift.io cluster -n openshift-machine-api -ojson | jq -r '.spec.template."machines_v1beta1_machine_openshift_io".spec.providerSpec.value.subnet')
if [[ "${master_sunbet_name}" == "${cpms_subnet}" ]]; then
    echo "INFO: cpms check pass!"
else
    echo "ERROR: cpms check failed! acutal value: ${cpms_subnet}, expected value: ${master_sunbet_name}"
    check_result=1
fi

#worker machineset check
echo "Worker machienset checking..."
worker_machinesets=$(oc get machinesets.machine.openshift.io -n openshift-machine-api -ojson | jq -r '.items[].metadata.name')
for machineset in ${worker_machinesets}; do
    machineset_subnet=$(oc get machinesets.machine.openshift.io -n openshift-machine-api ${machineset} -ojson | jq -r '.spec.template.spec.providerSpec.value.subnet')
    match_count=$(echo "${subnets_json_array}" | jq --arg name "${machineset_subnet}" '[.[] | select(.name == $name)] | length')
    if [[ ${match_count} -gt 0 ]]; then
        echo "INFO: subnet ${machineset_subnet} is found in worker machineset ${machineset}!"
        worker_natgateway_zone=$(echo "${subnets_json_array}" | jq -r --arg name "${machineset_subnet}" '.[] | select(.name == $name) | .zone')
        if [[ -n "${worker_natgateway_zone}" ]] && [[ "${worker_natgateway_zone}" != "null" ]]; then
            machineset_zone=$(oc get machinesets.machine.openshift.io -n openshift-machine-api ${machineset} -ojson | jq -r '.spec.template.spec.providerSpec.value.zone')
            if [[ "${worker_natgateway_zone}" == "${machineset_zone}" ]]; then
                echo "INFO: natgateway and machineset are in the same zone!"
            else
                echo "ERROR: natgateway and machineset are in the different zone! natgateway: ${worker_natgateway_zone}; machineset ${machineset}: ${machineset_zone}"
                check_result=1
            fi
        fi
    else
        echo "ERROR: worker machienset ${machineset} check failed! subnet in machineset is ${machineset_subnet}, expect subnets are {subnets_json_array}!"
        check_result=1
    fi
done

exit ${check_result}
