#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov)
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    # BASE_DOMAIN=$(yq-go r "${INSTALL_CONFIG}" 'baseDomain')
    ;;
gcp)
    BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
    GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
    export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
    sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
    if ! gcloud auth list | grep -E "\*\s+${sa_email}"
    then
        gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
        gcloud config set project "${GOOGLE_PROJECT_ID}"
    fi
    ;;
*)
    echo "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
    ;;
esac

# REGION="${LEASED_RESOURCE}"
# INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
# CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
CLUSTER_NAME=$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')
PUBLISH_STRATEGY=$(yq-go r "${INSTALL_CONFIG}" 'publish')


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
            echo "ERROR: No valid PUBLIC_ZONE_ID found."
            ret=$((ret+1))    
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
            echo "ERROR: No valid base_domain_zone_name found."
            ret=$((ret + 1))
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
esac

exit $ret
