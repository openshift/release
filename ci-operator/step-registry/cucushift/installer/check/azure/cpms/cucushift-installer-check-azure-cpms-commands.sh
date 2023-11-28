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

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
if (( ${ocp_minor_version} < 14 )); then
    echo "CPMS failureDomain check is only available on 4.14+ cluster, skip the check!"
    exit 0
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi
REGION=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.region')

expected_platform=""
expected_zones=""
readarray -t zones_setting_from_config < <(yq-go r ${INSTALL_CONFIG} 'controlPlane.platform.azure.zones[*]')
echo "zones_setting_from_config: ${zones_setting_from_config[*]}"
if (( ${#zones_setting_from_config[@]} > 1 )); then
    echo "INFO: multi zones specified on master node in install-config"
    expected_platform="Azure"
    expected_zones="${zones_setting_from_config[*]}"
elif (( ${#zones_setting_from_config[@]} == 0 )); then
    echo "Field zones is not set in install-config, check if instance type supports zone or only single zone in region ${REGION}"
    # Get master instance type
    master_instance_type=$(oc get machine --selector machine.openshift.io/cluster-api-machine-type=master -n openshift-machine-api -ojson | jq -r '.items[].spec.providerSpec.value.vmSize' | sort -u)
    readarray -t zones_config < <(az vm list-skus -l "${REGION}" --zone --size "${master_instance_type}" --query '[].locationInfo[].zones[]' -otsv)
    echo "zones_config: ${zones_config[*]}"
    if (( ${#zones_config[@]} > 1 )); then
        echo "INFO: multi zones config for instance type ${master_instance_type} in region ${REGION}"
        expected_platform="Azure"
        expected_zones="${zones_config[*]}"
    else
        echo "INFO: single zone for instance type ${master_instance_type} in region ${REGION} or zone unsupported in region ${REGION}"
    fi
else
    echo "INFO: single zone specified on master node in install-config"
fi

check_result=0
echo "Check CPMS failureDomain contains expected plaform and zone setting"
echo -e "ocp_minor_version:${ocp_minor_version}\nregion:${REGION}\nexpected_platform: ${expected_platform}\nexpected_zones: ${expected_zones}"
#check platform
echo "cpms spec:"
oc get controlplanemachineset cluster -n openshift-machine-api -ojson | jq -r '.spec.template."machines_v1beta1_machine_openshift_io"'
platform_value=$(oc get controlplanemachineset cluster -n openshift-machine-api -ojson | jq -r '.spec.template."machines_v1beta1_machine_openshift_io".failureDomains.platform')
if [[ "${platform_value}" != "null" ]]; then
    if [[ "${platform_value}" == "${expected_platform}" ]]; then
        echo "INFO: the platform in CPMS failureDomain is set as expected!"
    else
        echo "ERROR: the platform in CPMS failureDomain is ${platform_value}, which does not match expected value, unexpected!"
        check_result=1
    fi
else
    # On 4.15+, no failureDomain object is set when installing on singel zone or region without avaiable zone support.
    if (( ${ocp_minor_version} > 14 )); then
        failure_domain_value=$(oc get controlplanemachineset cluster -n openshift-machine-api -ojson | jq -r '.spec.template."machines_v1beta1_machine_openshift_io".failureDomains')
        if [[ "${failure_domain_value}" == "null" ]] && [[ -z "${expected_platform}" ]]; then
            echo "INFO: detect single zone or region without avaiable zone support on 4.15+, get expected behavior that no failureDomain object is set in cpms spec!"
        else
            echo "ERROR: detect single zone or region without avaiable zone support on 4.15+, failureDomain is still set in cpms spec, unexpected!"
            check_result=1
        fi
    else
        echo "ERROR: Not found field platform in cpms spec, unexpected!"
        check_result=1
    fi
fi

#check zones
if [[ "${platform_value}" != "" ]] && [[ "${platform_value}" != "null" ]]; then
    zones_value=$(oc get controlplanemachineset cluster -n openshift-machine-api -oyaml | yq-go r - "spec.template.machines_v1beta1_machine_openshift_io.failureDomains.azure[*].zone" | sort -u | xargs)
    [[ "${expected_zones}" != "" ]] && expected_zones=$(echo ${expected_zones} | xargs -n1 | sort -u | xargs)
    if [[ "${zones_value}" != "${expected_zones}" ]]; then
        echo "ERROR: the zones in CPMS failureDomain are ${zones_value}, which do not match expected value, unexpected!"
        check_result=1
    else
        echo "INFO: the zones in CPMS failureDomain are set as expected!"
    fi
fi

exit ${check_result}
