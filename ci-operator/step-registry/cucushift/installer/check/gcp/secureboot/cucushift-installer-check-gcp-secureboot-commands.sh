#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

## Try the validation
ret=0

echo "$(date -u --rfc-3339=seconds) - Checking Secure Boot (i.e. Shielded VMs) settings of cluster machines..."
readarray -t machines < <(gcloud compute instances list --filter="name~${CLUSTER_NAME}" --format="table(name,zone)" | grep -v NAME)
for line in "${machines[@]}"; do
  machine_name="${line%% *}"
  machine_zone="${line##* }"
  gcloud compute instances describe "${machine_name}" --zone "${machine_zone}" --format json > "/tmp/${CLUSTER_NAME}-machine.json"
  secureboot="$(jq -r -c .shieldedInstanceConfig.enableSecureBoot "/tmp/${CLUSTER_NAME}-machine.json")"

  if [[ "${secureboot}" == true ]]; then
    echo "$(date -u --rfc-3339=seconds) - Matched .enableSecureBoot '${secureboot}' for '${machine_name}'."
  else
    echo "$(date -u --rfc-3339=seconds) - Unexpected .enableSecureBoot '${secureboot}' for '${machine_name}'."
    ret=1
  fi
done

exit ${ret}
