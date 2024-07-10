#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

mkdir -p terraform_quay_security_testing && cd terraform_quay_security_testing
cp ${SHARED_DIR}/terraform.tgz .
tar -xzvf terraform.tgz && ls
QUAY_SECURITY_TESTING_NAME=$(cat ${SHARED_DIR}/QUAY_SECURITY_TESTING_NAME)
QUAY_SECURITY_TESTING_HOST_NAME=$(cat ${SHARED_DIR}/QUAY_SECURITY_TESTING_HOST_NAME)
echo "Start to destroy quay security testing host $QUAY_SECURITY_TESTING_HOST_NAME ..."

#Destroy Quay Security Testing Host
export TF_VAR_quay_build_instance_name="${QUAY_SECURITY_TESTING_NAME}"
export TF_VAR_quay_build_worker_key="${QUAY_SECURITY_TESTING_NAME}"
export TF_VAR_quay_build_worker_security_group="${QUAY_SECURITY_TESTING_NAME}"
terraform init
terraform destroy -auto-approve || true
