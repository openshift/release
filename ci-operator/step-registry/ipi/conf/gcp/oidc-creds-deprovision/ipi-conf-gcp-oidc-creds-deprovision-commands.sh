#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

infra_name=${NAMESPACE}-${JOB_NAME_HASH}
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

# delete credentials infrastructure created by oidc-creds-provision-provision configure step
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
ccoctl gcp delete --name="${infra_name}" --project="${PROJECT}"
