#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov)
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    ;;
gcp)
    GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
    export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
    sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
    if ! gcloud auth list | grep -E "\*\s+${sa_email}"
    then
        gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
        gcloud config set project "${GOOGLE_PROJECT_ID}"
    fi
    ;;
azure4|azuremag|azurestack)
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
    ;;
*)
    echo "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
    ;;
esac

# REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
# CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
CLUSTER_NAME=$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')
PUBLISH_STRATEGY=$(yq-go r "${INSTALL_CONFIG}" 'publish')
BASE_DOMAIN=$(yq-go r "${INSTALL_CONFIG}" 'baseDomain')


ret=0

# ------------------------------------------------------------------------------
# Check if DNS records were created
# ------------------------------------------------------------------------------
echo "Checking if private zone were created."
case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov)
    # records in public zone
    if [[ ${PUBLISH_STRATEGY} != "Internal" ]]; then
        echo "Checking records in public zone."
        PUBLIC_ZONE_ID=$(aws route53 list-hosted-zones-by-name | jq --arg name "${BASE_DOMAIN}." -r '.HostedZones | .[] | select(.Name=="\($name)") | .Id' | awk -F / '{printf $3}')
        if [[ -n "${PUBLIC_ZONE_ID}" ]]; then
            PUBLIC_RECORD_SETS=$(aws route53 list-resource-record-sets --hosted-zone-id=${PUBLIC_ZONE_ID} --output json | jq '.ResourceRecordSets[].Name' |grep "${CLUSTER_NAME}.${BASE_DOMAIN}" || true)

            if [[ -n "${PUBLIC_RECORD_SETS}" ]]; then
                echo "ERROR: Found DNS records for ${CLUSTER_NAME}.${BASE_DOMAIN}"
                echo "${PUBLIC_RECORD_SETS}"
                ret=$((ret + 1))
            else
                echo "PASS: No DNS records for ${CLUSTER_NAME}.${BASE_DOMAIN}"
            fi
        else
            echo "PASS: No valid PUBLIC_ZONE_ID found on this platform, no public records would be created."
        fi
    fi

    # private zone
    echo "Checking private hosted zone for ${CLUSTER_NAME}.${BASE_DOMAIN}"
    PRIVATE_HOSTED_ZONE=$(aws route53 list-hosted-zones --hosted-zone-type PrivateHostedZone | jq -r '.HostedZones[].Name' | grep "${CLUSTER_NAME}.${BASE_DOMAIN}" || true)
    if [[ ${PRIVATE_HOSTED_ZONE} != "" ]]; then
        echo "ERROR: Found private zone: ${PRIVATE_HOSTED_ZONE}"
        ret=$((ret+1))
    else
        echo "PASS: No private hosted zone created."
    fi
    ;;
gcp)
    # records in public zone
    if [[ ${PUBLISH_STRATEGY} != "Internal" ]]; then
        echo "Checking records in public zone."
        base_domain_zone_name=$(gcloud dns managed-zones list --filter="visibility=public AND dnsName=${BASE_DOMAIN}." --format="value(name)")
        if [[ -n "${base_domain_zone_name}" ]]; then
            # In case of a disconnected network, it's possible to configure record-sets for the mirror registry (within the VPC), so exclude it. 
            PUBLIC_RECORD_SETS=$(gcloud dns record-sets list --zone "${base_domain_zone_name}" | grep -v mirror-registry | grep "${CLUSTER_NAME}.${BASE_DOMAIN}" || true)
            if [[ ${PUBLIC_RECORD_SETS} != "" ]]; then
                echo "ERROR: Found DNS records for ${CLUSTER_NAME}.${BASE_DOMAIN}"
                echo "${PUBLIC_RECORD_SETS}"
                ret=$((ret + 1))
            else
                echo "PASS: No DNS records for ${CLUSTER_NAME}.${BASE_DOMAIN}"
            fi
        else
            echo "PASS: No valid base_domain_zone_name found on this platform, no records would be created."
        fi
    fi

    # private zone
    echo "Checking private hosted zone for ${CLUSTER_NAME}.${BASE_DOMAIN}"
    PRIVATE_HOSTED_ZONE=$(gcloud dns managed-zones list --filter="visibility=private" | grep "${CLUSTER_NAME}.${BASE_DOMAIN}" || true)
    if [[ ${PRIVATE_HOSTED_ZONE} != "" ]]; then
        echo "ERROR: Found private zone: ${PRIVATE_HOSTED_ZONE}"
        ret=$((ret+1))
    else
        echo "PASS: No private hosted zone created."
    fi
    ;;
azure4|azuremag|azurestack)
    # record in public zone
    BASE_DOMAIN_RG="$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.baseDomainResourceGroupName')"
    CLUSTER_RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
    if [[ -z "${CLUSTER_RESOURCE_GROUP}" ]]; then
        CLUSTER_RESOURCE_GROUP="${INFRA_ID}-rg"
    fi
    dns_records_list=""

    if [[ "${PUBLISH_STRATEGY}" == "External" ]]; then
        dns_records_list="api.${CLUSTER_NAME} *.apps.${CLUSTER_NAME}"
    elif [[ "${PUBLISH_STRATEGY}" == "Mixed" ]]; then
        api_publish_strategy=$(yq-go r "${INSTALL_CONFIG}" 'operatorPublishingStrategy.apiserver')
        ingress_publish_strategy=$(yq-go r "${INSTALL_CONFIG}" 'operatorPublishingStrategy.ingress')
        if [[ "${api_publish_strategy}" == "External" ]] || [[ -z "${api_publish_strategy}" ]]; then
             dns_records_list="api.${CLUSTER_NAME}"
        fi

        if [[ "${ingress_publish_strategy}" == "External" ]] || [[ -z "${ingress_publish_strategy}" ]]; then
             dns_records_list="${dns_records_list} *.apps.${CLUSTER_NAME}"
        fi
    fi

    if [[ -n "${dns_records_list}" ]]; then
        echo "Checking records in public zone."
        for record in ${dns_records_list}; do
            public_record_sets=$(az network dns record-set list -g ${BASE_DOMAIN_RG} -z ${BASE_DOMAIN} --query "[?contains(name, '${record}')]" -otsv)
            if [[ -z "${public_record_sets}" ]]; then
                echo "PASS: record ${record} is not found in base domain ${BASE_DOMAIN}!"
            else
               echo "ERROR: found record ${record} in base domain ${BASE_DOMAIN}!"
               echo "${public_record_sets}"
               ret=$((ret+1))
            fi
        done
    fi

    # private zone
    echo "Checking private dns zone for ${CLUSTER_NAME}.${BASE_DOMAIN}"
    private_dns_zone="$(az network private-dns zone list -g ${CLUSTER_RESOURCE_GROUP} -otsv)"
    if [[ -z "${private_dns_zone}" ]]; then
        echo "PASS: No private dns zone created."
    else
        echo "ERROR: found private dns zone in cluster resource group ${CLUSTER_RESOURCE_GROUP}!"
        echo "${private_dns_zone}"
        ret=$((ret+1))
    fi
    ;;
esac

exit $ret
