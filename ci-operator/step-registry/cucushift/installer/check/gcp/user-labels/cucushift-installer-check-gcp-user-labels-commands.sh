#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ ! -f "${SHARED_DIR}/user_tags_sa.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the key file of the IAM service-account for userTags testing on GCP."
  exit 1
fi

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
INFRA_ID="$(oc get infrastructures.config.openshift.io cluster -o jsonpath='{.status.infrastructureName}')"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${SHARED_DIR}/user_tags_sa.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

# User-defined labels validation. It will check if each user-defined label is applied. 
# Return non-zero is one or more user-defined label absent. 
# $1 - the current labels of the resource under question (JSON in compact format)
function validate_user_labels() {
  local -r current_labels_str="$1";  shift

  printf '%s' "${USER_LABELS:-}" | while read -r KEY VALUE || [ -n "${KEY}" ]
  do
    a_key_and_value="\"${KEY}\":\"${VALUE}\""
    if [[ ! ${current_labels_str} =~ ${a_key_and_value} ]]; then
      echo "$(date -u --rfc-3339=seconds) - Failed to find label '${a_key_and_value}'."
      echo -e "Expected user-defined labels: \n${USER_LABELS}\nCurrent labels: ${current_labels_str}"
      return 1
    fi
  done
}

## Try the validation
set +e
ret=0

echo "$(date -u --rfc-3339=seconds) - Checking userLabels of compute instances..."
readarray -t items < <(gcloud compute instances list --filter="name~${CLUSTER_NAME}" --format="table(name,zone)" | grep -v NAME)
for line in "${items[@]}"; do
  name="${line%% *}"
  zone="${line##* }"
  current_labels="$(gcloud compute instances describe ${name} --zone ${zone} --format json | jq -r -c .labels)"
  validate_user_labels "${current_labels}"
  if [ $? -gt 0 ]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected labels '${current_labels}' for instance '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched labels '${current_labels}' for instance '${name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - Checking userLabels of compute disks..."
readarray -t items < <(gcloud compute disks list --filter="name~${CLUSTER_NAME}" --format="table(name,zone)" | grep -v NAME)
for line in "${items[@]}"; do
  name="${line%% *}"
  zone="${line##* }"
  current_labels="$(gcloud compute disks describe ${name} --zone ${zone} --format json | jq -r -c .labels)"
  validate_user_labels "${current_labels}"
  if [ $? -gt 0 ]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected labels '${current_labels}' for disk '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched labels '${current_labels}' for disk '${name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - Checking userLabels of forwarding-rules (created by installer)..."
readarray -t items < <(gcloud compute forwarding-rules list --filter="name~${CLUSTER_NAME}" --format="table(name,region)" | grep -v NAME)
for line in "${items[@]}"; do
  name="${line%% *}"
  region="${line##* }"
  if [[ "${region}" == "${name}" ]]; then
    current_labels="$(gcloud compute forwarding-rules describe ${name} --global --format json | jq -r -c .labels)"
  else
    current_labels="$(gcloud compute forwarding-rules describe ${name} --region ${region} --format json | jq -r -c .labels)"
  fi
  validate_user_labels "${current_labels}"
  if [ $? -gt 0 ]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected labels '${current_labels}' for forwarding-rule '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched labels '${current_labels}' for forwarding-rule '${name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - Checking userLabels of dns private zone..."
readarray -t items < <(gcloud dns managed-zones list --filter="name~${CLUSTER_NAME}" --format="table(name)" | grep -v NAME)
for line in "${items[@]}"; do
  name="${line}"
  current_labels="$(gcloud dns managed-zones describe ${name} --format json | jq -r -c .labels)"
  validate_user_labels "${current_labels}"
  if [ $? -gt 0 ]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected labels '${current_labels}' for dns private zone '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched labels '${current_labels}' for dns private zone '${name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - Checking userLabels of image-registry buckets..."
readarray -t items < <(gsutil ls | grep "${INFRA_ID}-image-registry")
for line in "${items[@]}"; do
  name="${line}"
  current_labels="$(gsutil label get ${name} | jq -r -c .)"
  validate_user_labels "${current_labels}"
  if [ $? -gt 0 ]; then
    echo "$(date -u --rfc-3339=seconds) - Unexpected labels '${current_labels}' for image-registry bucket '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - Matched labels '${current_labels}' for image-registry bucket '${name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - exit code '${ret}'"
exit ${ret}
