#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script will destroy s3 bucket and cloudfront that step configure-registry-storage-deploy-s3-cloudfront generated.

if [[ -f "${SHARED_DIR}/create_s3_bucket_for_registry_storage.tf" ]]; then
  echo "Destroy s3 cloudfront setting"
  mv "${SHARED_DIR}/create_s3_bucket_for_registry_storage.tf" /tmp && cd /tmp
  tar -xf "${SHARED_DIR}/s3_cloudfront_terraform_state.tar.xz"
  terraform init
  terraform destroy -refresh=false -auto-approve -no-color
else
  echo "This cluster does not set cloudfront"
fi
