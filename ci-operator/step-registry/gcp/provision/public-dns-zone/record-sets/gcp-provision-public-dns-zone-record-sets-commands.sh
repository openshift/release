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

echo "Waiting for ${GCP_NEW_PUBLIC_DNS_RECORD_WAITING_TIME}s to ensure DNS records can be resolved ..."
sleep $GCP_NEW_PUBLIC_DNS_RECORD_WAITING_TIME

