#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

# CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

if [ ! -e "${SHARED_DIR}/public_custom_dns.json" ]; then
    echo "ERROR: No public_custom_dns.json found, exit now"
    exit 1
fi

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gcp-dns-admin.json"
project_id=$(jq -r '.project_id' "${CLUSTER_PROFILE_DIR}/gcp-dns-admin.json")
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${project_id}"
fi

base_domain_zone_name=$(gcloud dns managed-zones list --filter="visibility=public AND dnsName=${BASE_DOMAIN}." --format="value(name)")

if [[ "${base_domain_zone_name}" == "" ]]; then
    echo "ERROR: can not fetch zone name of ${BASE_DOMAIN}, exit now."
    exit 1
fi

count=$(jq '.|length' ${SHARED_DIR}/public_custom_dns.json)
for i in $(seq 0 $((count-1)));
do
    name=$(jq --argjson i $i -r '.[$i].name' ${SHARED_DIR}/public_custom_dns.json)
    target=$(jq --argjson i $i -r '.[$i].target' ${SHARED_DIR}/public_custom_dns.json)
    record_type=$(jq --argjson i $i -r '.[$i].record_type' ${SHARED_DIR}/public_custom_dns.json)
    echo "Adding record: $name $target $record_type"
    gcloud --project ${project_id} dns record-sets create ${name} --rrdatas=${target} --ttl 60 --type ${record_type} --zone ${base_domain_zone_name}

    cat >> "${SHARED_DIR}/record-sets-destroy.sh" << EOF
gcloud --project ${project_id} dns record-sets delete ${name} --type ${record_type} --zone ${base_domain_zone_name}
EOF
done

echo "Verifying DNS records can be resolved locally..."

# Verify each created record
for i in $(seq 0 $((count-1)));
do
    name=$(jq --argjson i $i -r '.[$i].name' ${SHARED_DIR}/public_custom_dns.json)
    target=$(jq --argjson i $i -r '.[$i].target' ${SHARED_DIR}/public_custom_dns.json)
    record_type=$(jq --argjson i $i -r '.[$i].record_type' ${SHARED_DIR}/public_custom_dns.json)

    echo "Verifying record: $name ($record_type)"

    # Try up to 30 times with 10 second intervals (5 minutes total)
    retry_count=0
    max_retries=30
    verified=false

    while [[ $retry_count -lt $max_retries ]]; do
        if dig +short ${name} ${record_type} | grep -qF "${target}"; then
            echo "Record ${name} verified and resolvable"
            verified=true
            break
        fi

        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            echo "Waiting for DNS propagation... (attempt ${retry_count}/${max_retries})"
            sleep 10
        fi
    done

    if [[ "${verified}" != "true" ]]; then
        echo "ERROR: Record ${name} could not be resolved after ${max_retries} attempts"
	exit 1
    fi
done

echo "DNS verification complete"
