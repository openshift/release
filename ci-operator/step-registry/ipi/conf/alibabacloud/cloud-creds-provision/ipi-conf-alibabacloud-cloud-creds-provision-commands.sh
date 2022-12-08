#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CR_PATH="/tmp/credrequests"
MPREFIX="${SHARED_DIR}/manifest"
cluster_id="${NAMESPACE}-${JOB_NAME_HASH}"
export ALIBABA_CLOUD_CREDENTIALS_FILE="${SHARED_DIR}/alibabacreds.ini"

# extract ccoctl from the release image
oc registry login
# extract alibabacloud credentials requests from the release image
# shellcheck disable=SC2153
REPO=$(oc -n ${NAMESPACE} get is release -o json | jq -r '.status.publicDockerImageRepository')
oc --loglevel 10 adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --credentials-requests --cloud=alibabacloud --to="${CR_PATH}" "${REPO}:latest"

# create required credentials infrastructure and installer manifests for workload identity
ccoctl alibabacloud create-ram-users \
    --region "${LEASED_RESOURCE}" \
    --name="${cluster_id}" \
    --credentials-requests-dir="${CR_PATH}" \
    --output-dir="/tmp"

cd "/tmp/manifests"
# copy generated secret manifests from ccoctl target directory into shared directory
for FILE in *; do cp "${FILE}" "${MPREFIX}_${FILE}"; done
