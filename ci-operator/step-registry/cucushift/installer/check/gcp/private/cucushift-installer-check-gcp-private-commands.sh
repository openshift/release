#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
GCP_REGION="${LEASED_RESOURCE}"

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ret=0

echo "INFO: (1/4) Checking publish policy..."
publish_policy=$(oc get configmap -n kube-system cluster-config-v1 -oyaml | grep 'publish:')
echo "INFO: ${publish_policy}"
if [[ "${publish_policy}" =~ "publish: Internal" ]]; then
    echo "INFO: Publish policy check passed."
else
    echo "ERROR: Publish policy check failed."
    ret=$(( $ret | 1 ))
fi

echo "INFO: (2/4) Checking if any dns record-sets in the base domain (public zone)..."
base_domain_zone_name=$(gcloud dns managed-zones list --filter="dnsName=${GCP_BASE_DOMAIN}." --format="table(name)" | grep -v NAME)
echo "INFO: base domain zone name '${base_domain_zone_name}'"
gcloud dns record-sets list --zone "${base_domain_zone_name}" | grep "${CLUSTER_NAME}" && ret=$(( $ret | 2 ))
if [ ${ret} -ge 2 ]; then
    echo "ERROR: Base domain record-sets check failed."
else
    echo "INFO: Base domain record-sets check passed."
fi

echo "INFO: (3/4) Checking if any external address..."
gcloud compute addresses list | grep -E "${CLUSTER_NAME}.*EXTERNAL" && ret=$(( $ret | 4 ))
if [ ${ret} -ge 4 ]; then
    echo "ERROR: External address check failed."
else
    echo "INFO: External address check passed."
fi

echo "INFO: (4/4) Checking forwarding-rules and see if any target pool..."
readarray -t forwardin_rules < <(gcloud compute forwarding-rules list --filter="name~${CLUSTER_NAME}" --format="table(name)" | grep -v NAME)
for forwardin_rule in "${forwardin_rules[@]}";
do
    gcloud compute forwarding-rules describe "${forwardin_rule}" --region "${GCP_REGION}"
done
gcloud compute target-pools list | grep "${CLUSTER_NAME}" && ret=$(( $ret | 8 ))
if [ ${ret} -ge 8 ]; then
    echo "ERROR: Target-pools check failed."
else
    echo "INFO: Target-pools check passed."
fi

echo "Exit code '${ret}'"
exit ${ret}