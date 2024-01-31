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

INFRA_ID="$(oc get infrastructures.config.openshift.io cluster -o jsonpath='{.status.infrastructureName}')"
GCP_REGION="${LEASED_RESOURCE}"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${SHARED_DIR}/user_tags_sa.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

validation_result_file=$(mktemp)

# User-defined tags validation. It will check if each user-defined tag is applied. 
# Return non-zero is one or more user-defined tag absent. 
# $1 - the current tags of the resource under question
function validate_user_tags() {
  local -r current_tags="$1";  shift

  local cnt=1 a_tag_value
  echo "" > "${validation_result_file}"
  printf '%s' "${USER_TAGS:-}" | while read -r PARENT KEY VALUE || [ -n "${PARENT}" ]
  do
    a_tag_value="namespacedTagValue: ${PARENT}/${KEY}/${VALUE}"
    if echo "${current_tags}" | grep -Fq "${a_tag_value}"; then
      echo "$(date -u --rfc-3339=seconds) - Found tag ${cnt} '${a_tag_value}' (PARENT/KEY/VALUE)."
      cnt=$(( $cnt + 1 ))
      echo 0 >> "${validation_result_file}"
      continue
    else
      echo "$(date -u --rfc-3339=seconds) - Failed to find tag '${a_tag_value}' (PARENT/KEY/VALUE)."
      echo 1 >> "${validation_result_file}"
    fi
  done
}

## Try the validation
ret=0

echo "$(date -u --rfc-3339=seconds) - Checking userTags of machines..."
readarray -t items < <(gcloud compute instances list --filter="name~${CLUSTER_NAME}" --format="table(name,zone)" | grep -v NAME)
for line in "${items[@]}"; do
  name="${line%% *}"
  zone="${line##* }"
  current_tags="$(gcloud resource-manager tags bindings list --parent=//compute.googleapis.com/projects/${GOOGLE_PROJECT_ID}/zones/${zone}/instances/${name} --location=${zone} --effective)"
  echo "${current_tags}"
  validate_user_tags "${current_tags}"
  if grep -q "1" "${validation_result_file}"; then
    echo "$(date -u --rfc-3339=seconds) - FAILED for machine '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - PASSED for machine '${name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - Checking userTags of disks..."
readarray -t items < <(gcloud compute disks list --filter="name~${CLUSTER_NAME}" --format="table(name,zone)" | grep -v NAME)
for line in "${items[@]}"; do
  name="${line%% *}"
  zone="${line##* }"
  zone=$(basename ${zone})
  disk_id=$(gcloud compute disks describe ${name} --zone ${zone} --format json | jq -r -c .id)
  current_tags="$(gcloud resource-manager tags bindings list --parent=//compute.googleapis.com/projects/${GOOGLE_PROJECT_ID}/zones/${zone}/disks/${disk_id} --location=${zone} --effective)"
  echo "${current_tags}"
  validate_user_tags "${current_tags}"
  if grep -q "1" "${validation_result_file}"; then
    echo "$(date -u --rfc-3339=seconds) - FAILED for disk '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - PASSED for disk '${name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - Checking userTags of image-registry buckets..."
readarray -t items < <(gsutil ls | grep "${INFRA_ID}-image-registry")
for line in "${items[@]}"; do
  name=$(basename "${line}")
  current_tags="$(gcloud resource-manager tags bindings list --parent=//storage.googleapis.com/projects/_/buckets/${name} --location=${GCP_REGION} --effective)"
  echo "${current_tags}"
  validate_user_tags "${current_tags}"
  if grep -q "1" "${validation_result_file}"; then
    echo "$(date -u --rfc-3339=seconds) - FAILED for bucket '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - PASSED for bucket '${name}'."
  fi
done

rm -f "${validation_result_file}"
echo "$(date -u --rfc-3339=seconds) - exit code '${ret}'"
exit ${ret}
