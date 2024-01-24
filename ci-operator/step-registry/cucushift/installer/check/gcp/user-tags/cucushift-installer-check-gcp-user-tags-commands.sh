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

# User-defined tags validation. It will check if each user-defined tag is applied. 
# Return non-zero is one or more user-defined tag absent. 
# $1 - the current tags of the resource under question
function validate_user_tags() {
  local -r current_tags="$1";  shift

  printf '%s' "${USER_TAGS:-}" | while read -r PARENT KEY VALUE || [ -n "${PARENT}" ]
  do
    a_tag_value="${PARENT}/${KEY}/${VALUE}"
    space_pattern="\ "
    if [[ "${a_tag_value}" =~ ${space_pattern} ]] && [ ${#a_tag_value} -gt 64 ]; then
      echo "$(date -u --rfc-3339=seconds) - Truncating tag '${a_tag_value}'"
      a_tag_value="${a_tag_value::63}"
      a_tag_value="${a_tag_value%* }"
    fi
    a_tag_value="namespacedTagValue: ${a_tag_value}"
    if echo "${current_tags}" | grep -Fq "${a_tag_value}"; then
      continue
    else
      echo "$(date -u --rfc-3339=seconds) - Failed to find tag '${a_tag_value}' (PARENT/KEY/VALUE)."
      return 1
    fi
  done
}

## Try the validation
ret=0

echo "$(date -u --rfc-3339=seconds) - Checking userTags of image-registry buckets..."
readarray -t items < <(gsutil ls | grep "${INFRA_ID}-image-registry")
for line in "${items[@]}"; do
  name=$(basename "${line}")
  current_tags="$(gcloud resource-manager tags bindings list --parent=//storage.googleapis.com/projects/_/buckets/${name} --location=${GCP_REGION} --effective)"
  echo "${current_tags}"
  validate_user_tags "${current_tags}" || tmp_ret=$?
  if [ $tmp_ret -gt 0 ]; then
    echo "$(date -u --rfc-3339=seconds) - FAILED for bucket '${name}'."
    ret=1
  else
    echo "$(date -u --rfc-3339=seconds) - PASSED for bucket '${name}'."
  fi
done

echo "$(date -u --rfc-3339=seconds) - exit code '${ret}'"
exit ${ret}
