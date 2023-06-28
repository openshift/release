#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
cluster_id="${NAMESPACE}-${UNIQUE_HASH}"

# delete credentials infrastructure created by cloud-creds-provision configure step
ccoctl alibabacloud \
  delete-ram-users \
  --name="${cluster_id}"
