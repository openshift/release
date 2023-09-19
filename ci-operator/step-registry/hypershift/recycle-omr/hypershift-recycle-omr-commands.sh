#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


#Check podman and skopeo version
mkdir -p terraform_omr && cd terraform_omr
cp ${SHARED_DIR}/terraform.tgz .
tar -xzvf terraform.tgz && ls
OMR_CI_NAME=$(cat ${SHARED_DIR}/OMR_CI_NAME)
OMR_HOST_NAME=$(cat ${SHARED_DIR}/OMR_HOST_NAME)
echo "Start to destroy OMR $OMR_HOST_NAME ..."

#Destroy Quay OMR
export TF_VAR_quay_build_instance_name="${OMR_CI_NAME}"
export TF_VAR_quay_build_worker_key="${OMR_CI_NAME}"
export TF_VAR_quay_build_worker_security_group="${OMR_CI_NAME}"
terraform init
terraform destroy -auto-approve || true
