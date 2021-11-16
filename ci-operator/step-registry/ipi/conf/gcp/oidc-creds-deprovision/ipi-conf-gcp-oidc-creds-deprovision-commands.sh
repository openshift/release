#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

infra_name=${NAMESPACE}-${JOB_NAME_HASH}
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

# extract ccoctl from the release image
CCO_IMAGE=$(oc adm release info --image-for='cloud-credential-operator' "$RELEASE_IMAGE_LATEST")
cd "/tmp"
oc image extract "$CCO_IMAGE" --file="/usr/bin/ccoctl"
chmod 555 "/tmp/ccoctl"

# delete credentials infrastructure created by oidc-creds-provision-provision configure step
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
"/tmp/ccoctl" gcp delete --name="${infra_name}" --project="${PROJECT}"
