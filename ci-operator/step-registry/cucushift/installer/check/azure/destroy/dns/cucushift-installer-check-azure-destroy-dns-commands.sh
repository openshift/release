#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
cluster_publish=$(yq-go r "${INSTALL_CONFIG}" 'publish')
if [[ "${cluster_publish}" == "Internal" ]]; then
    echo "This is a private cluster, skip to check public dns records."
    exit 0
fi

# az should already be there
command -v az
az --version

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
    # Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
    chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
    source ${SHARED_DIR}/azurestack-login-script.sh
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

base_domain=$(yq-go r "${INSTALL_CONFIG}" 'baseDomain')
base_domain_rg=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.baseDomainResourceGroupName')
cluster_name=$(jq -r '.clusterName' ${SHARED_DIR}/metadata.json)
infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
metadata_str="{'kubernetes.io_cluster.${infra_id}':'owned'}"
check_result=0

# case-1: ensure all cluster dns records are cleaned, even cluster resource group is removed prior to destoyer
dns_record_after_destroy=$(mktemp)
run_command "az network dns record-set list -g ${base_domain_rg} -z ${base_domain} --query '[?contains(name, \`$cluster_name\`) && !contains(name, \`mirror-registry\`)]' -o json | tee ${dns_record_after_destroy}"
dns_record_set_len=$(jq '.|length' "${dns_record_after_destroy}")
if [[ ${dns_record_set_len} -ne 0 ]]; then
    echo "Some cluter dns records are left after cluster is destroyed, something is wrong, please check!"
    exit 1
fi

if [[ "${EXTEND_AZURE_DESTROY_DNS_CHECK}" == "no" ]]; then
    echo "No extend testing for azure destroy dns check"
    exit 0
fi

# case-2: create dummy api and apps dns record, ensure destroyer can clean it up.
function check_destroy_dns() {
    local dns_name="$1" dns_type="$2" dns_value="$3" install_dir ret=1 action=""

    if [[ "${dns_type}" == "cname" ]]; then
        action="set-record --cname ${dns_value}"
    elif [[ "${dns_type}" == "a" ]]; then
        action="add-record --ipv4-address ${dns_value}"
    else
        echo "Not support ${dns_type} dns record type yet"
        return 1
    fi
    run_command "az network dns record-set ${dns_type} create -g ${base_domain_rg} -n ${dns_name} -z ${base_domain}" &&
    run_command "az network dns record-set ${dns_type} ${action} -g ${base_domain_rg} -n ${dns_name} -z ${base_domain}" &&
    run_command "az network dns record-set ${dns_type} update -g ${base_domain_rg} -n ${dns_name} -z ${base_domain} --metadata \"${metadata_str}\"" &&
    run_command "az network dns record-set ${dns_type} show -g ${base_domain_rg} -n ${dns_name} -z ${base_domain}" || return 1

    install_dir=$(mktemp -d) &&
    cp -r ${SHARED_DIR}/metadata.json "${install_dir}/" &&
    openshift-install destroy cluster --dir "${install_dir}" || return 1

    run_command "az network dns record-set ${dns_type} show -g ${base_domain_rg} -n ${dns_name} -z ${base_domain}" || ret=0
    return $ret
}

export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
  export AZURE_AUTH_LOCATION=$SHARED_DIR/osServicePrincipal.json
  if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
  fi
fi

check_destroy_dns "api.${cluster_name}" "cname" "a.b.com" || check_result=1
check_destroy_dns "*.apps.${cluster_name}" "a" "1.1.2.2" || check_result=1
# OCPBUGS-51094
#check_destroy_dns "*.test.${cluster_name}" "a" "1.1.3.3" || check_result=1

exit ${check_result}
