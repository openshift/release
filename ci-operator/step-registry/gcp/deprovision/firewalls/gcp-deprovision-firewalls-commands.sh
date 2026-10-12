#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

FIREWALL_RULES_DEPROVISION_SCRIPTS="${SHARED_DIR}/03_firewall_rules_deprovision.sh"

if ! test -f "${FIREWALL_RULES_DEPROVISION_SCRIPTS}"; then
  echo "Failed to find '${FIREWALL_RULES_DEPROVISION_SCRIPTS}', aborted." && exit 1
fi

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

## Destroy the firewall-rules
echo "$(date -u --rfc-3339=seconds) - Destroying the pre-created firewall-rules..."
sh "${FIREWALL_RULES_DEPROVISION_SCRIPTS}"
