#!/bin/bash

set -o nounset
set -o pipefail

# No errexit: every cleanup attempt runs even when an earlier one fails.
# No set -x: the API key and IAM token must never reach the log.

if [[ ! -s "${SHARED_DIR}/QUAY_IBMCLOUD_COS_INSTANCE_NAME" ]]; then
  echo "No QUAY_IBMCLOUD_COS_INSTANCE_NAME in SHARED_DIR; nothing to deprovision"
  exit 0
fi
name="$(cat "${SHARED_DIR}/QUAY_IBMCLOUD_COS_INSTANCE_NAME")"

export IBMCLOUD_HOME=/output
ibmcloud config --check-version=false
ibmcloud login -r "${LEASED_RESOURCE}" --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"

# Provision can fail between creating the instance and recording its GUID.
if [[ -s "${SHARED_DIR}/QUAY_IBMCLOUD_COS_INSTANCE_ID" ]]; then
  guid="$(cat "${SHARED_DIR}/QUAY_IBMCLOUD_COS_INSTANCE_ID")"
else
  guid="$(ibmcloud resource service-instance "${name}" --output json -q | jq -r '.[0].guid // empty')"
fi
if [[ -z "${guid}" ]]; then
  echo "No COS instance ${name} found; nothing to deprovision"
  exit 0
fi

if [[ -s "${SHARED_DIR}/QUAY_IBMCLOUD_COS_BUCKET" ]]; then
  bucket="$(cat "${SHARED_DIR}/QUAY_IBMCLOUD_COS_BUCKET")"
  url="https://$(cat "${SHARED_DIR}/QUAY_IBMCLOUD_COS_ENDPOINT")/${bucket}"
  token="$(ibmcloud iam oauth-tokens --output json | jq -r '.iam_token')"
  echo "Emptying bucket ${bucket}"
  continuation=""
  while :; do
    page="$(curl -sS --fail -H "Authorization: ${token}" "${url}?list-type=2${continuation}")" || break
    # Quay object keys are plain paths, so they need no XML-unescaping or URL-encoding.
    while read -r key; do
      [[ -n "${key}" ]] && curl -sS --fail -X DELETE -H "Authorization: ${token}" "${url}/${key}"
    done < <(grep -o '<Key>[^<]*</Key>' <<<"${page}" | sed -e 's|<Key>||' -e 's|</Key>||')
    next="$(grep -o '<NextContinuationToken>[^<]*</NextContinuationToken>' <<<"${page}" \
      | sed -e 's|<NextContinuationToken>||' -e 's|</NextContinuationToken>||')"
    [[ -n "${next}" ]] || break
    continuation="&continuation-token=$(jq -rn --arg t "${next}" '$t | @uri')"
  done
  echo "Deleting bucket ${bucket}"
  curl -sS --fail -X DELETE -H "Authorization: ${token}" "${url}"
fi

echo "Deleting COS instance ${guid}"
if ! ibmcloud resource service-instance-delete "${guid}" --recursive -f; then
  echo "ERROR: failed to delete COS instance ${guid}" >&2
  exit 1
fi

# A deleted instance stays reclaimable for 7 days unless its reclamation is
# deleted too; the reclamation appears asynchronously.
for _ in {1..6}; do
  reclamation="$(ibmcloud resource reclamations --resource-instance-id "${guid}" --output json -q | jq -r '.[0].id // empty')"
  if [[ -n "${reclamation}" ]]; then
    if ! ibmcloud resource reclamation-delete "${reclamation}" -f; then
      echo "WARN: failed to delete reclamation ${reclamation}; COS instance ${guid} stays reclaimable for 7 days" >&2
    fi
    exit 0
  fi
  sleep 10
done
echo "No reclamation found for COS instance ${guid}"
