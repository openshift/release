#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# create an id (similar to $USER in local running scripts)
if [[ -z "${JOB_NAME}" || -z "${BUILD_ID}" ]]; then
  RANDOM_ID=$(tr -dc a-z </dev/urandom | head -c 1; tr -dc a-z0-9 </dev/urandom | head -c 7)
  ID="aro-openshift-ci-${RANDOM_ID}"
else
  ID="aro-openshift-ci-${JOB_NAME}-${BUILD_ID}"
fi
echo "job specific name of resources: ${ID}"

# read CURL_PROXY from cluster profile secret
CURL_PROXY="$(<"${CLUSTER_PROFILE_DIR}/curl_proxy")"

cat >> "${SHARED_DIR}/vars.sh" << EOF
export AZURE_CLUSTER_RESOURCE_GROUP="${ID}"
export ARO_CLUSTER_SERVICE_PRINCIPAL_NAME="${ID}-csp"
export ARO_CLUSTER_NAME="${ID}"
export CURL_PROXY="${CURL_PROXY}"
EOF
