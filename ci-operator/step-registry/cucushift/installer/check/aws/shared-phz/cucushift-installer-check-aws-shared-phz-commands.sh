#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)

HOSTED_ZONE_ID_FILE="${SHARED_DIR}/hosted_zone_id"
if [ ! -f "${HOSTED_ZONE_ID_FILE}" ]; then
    echo "File ${HOSTED_ZONE_ID_FILE} does not exist."
    exit 1
fi
HOSTED_ZONE_ID="$(cat ${HOSTED_ZONE_ID_FILE})"

# CONFIG=${SHARED_DIR}/install-config.yaml

if [[ ${ENABLE_SHARED_PHZ} == "yes" ]]; then
  echo "Using shared AWS account."
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
else
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Checking, if "shared" tags were added to PHZ
aws --region $REGION route53 list-tags-for-resource --resource-type hostedzone --resource-id "${HOSTED_ZONE_ID}" | jq -r '.ResourceTagSet.Tags | from_entries' > ${ARTIFACT_DIR}/phz_tags.json
if ! grep -qE "kubernetes.io/cluster/${INFRA_ID}.*shared" ${ARTIFACT_DIR}/phz_tags.json; then
  echo "ERROR: ${HOSTED_ZONE_ID}: NOT found tag kubernetes.io/cluster/${INFRA_ID}:shared"
  exit 1
else
  echo "PASS: ${HOSTED_ZONE_ID}: Found tag kubernetes.io/cluster/${INFRA_ID}:shared"
fi

