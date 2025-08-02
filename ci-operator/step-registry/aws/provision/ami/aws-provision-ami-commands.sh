#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION=${REGION:-$LEASED_RESOURCE}
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"


function copy_ami()
{
    local ami_name=$1
    local source_region=$2 
    local source_ami_id=$3
    local target_region=$4
    local encrypted=$5
    local kms_id=$6
    local out=$7

    local cmd new_ami_id
    cmd=" aws --region $target_region ec2 copy-image"
    cmd=" ${cmd} --source-region ${source_region} --name ${ami_name} --source-image-id ${source_ami_id}"
    cmd=" ${cmd} --description 'Prow CI test: ${CLUSTER_NAME}'"
    if [[ "${encrypted}" == "yes" ]]; then
        cmd=" ${cmd} --encrypted"

        if echo ${kms_id} | grep -E '^[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}$'; then
            cmd=" ${cmd} --kms-key-id ${kms_id}"
        fi
    fi

    local tmp_out
    tmp_out=$(mktemp)

    echo "Copying image: ${cmd}"
    eval "${cmd}" | tee  $tmp_out
    new_ami_id=$(jq -r '.ImageId' ${tmp_out})

    echo "Waiting for image ${new_ami_id} available ..."
    local image_state try max_retries interval
    # timeout: 20 mins
    interval=30
    max_retries=40
    try=0

    while [ $try -lt $max_retries ]; do
        image_state=$(aws --region ${target_region} ec2 describe-images --image-ids ${new_ami_id} | jq -r '.Images[].State')
        if [ "${image_state}" != "available" ]; then
            echo "Image state: ${image_state}, waiting ... "$((interval*try))"s"
        else
            echo "Image is ready:"
            echo ${new_ami_id} > "${out}"
            aws --region ${target_region} ec2 describe-images --image-ids ${new_ami_id}
            return 0
        fi
        sleep $interval
        try=$(expr $try + 1)
    done

    echo "ERROR: waiting for image ready timeout."
    exit 1
}


ARCH="x86_64"
if [[ ${OCP_ARCH:-} == "arm64" ]]; then
    ARCH="aarch64"
fi

ami_name_prefix="Prow-CI-${CLUSTER_NAME}"
source_ami_id=$(openshift-install coreos print-stream-json | jq -r --arg a $ARCH --arg r $REGION '.architectures[$a].images.aws.regions[$r].image')
kms_key_id="no-kms-key"

if [[ "${ENABLE_AWS_AMI_DEFAULT_MACHINE}" == "yes" ]]; then
    if [ -f "${SHARED_DIR}/aws_kms_key_id" ]; then
        kms_key_id=$(< "${SHARED_DIR}/aws_kms_key_id")
    fi
    copy_ami "${ami_name_prefix}-default" ${REGION} ${source_ami_id} ${REGION} ${ENCRYPTED_AMI} ${kms_key_id} "${SHARED_DIR}/aws_ami"
fi

if [[ "${ENABLE_AWS_AMI_CONTROL_PLANE}" == "yes" ]]; then
    if [ -f "${SHARED_DIR}/aws_kms_key_id_control_plane" ]; then
        kms_key_id=$(< "${SHARED_DIR}/aws_kms_key_id_control_plane")
    fi
    copy_ami "${ami_name_prefix}-control-plane" ${REGION} ${source_ami_id} ${REGION} ${ENCRYPTED_AMI} ${kms_key_id} "${SHARED_DIR}/aws_ami_control_plane"
fi

if [[ "${ENABLE_AWS_AMI_COMPUTE}" == "yes" ]]; then
    if [ -f "${SHARED_DIR}/aws_kms_key_id_compute" ]; then
        kms_key_id=$(< "${SHARED_DIR}/aws_kms_key_id_compute")
    fi
    copy_ami "${ami_name_prefix}-compute" ${REGION} ${source_ami_id} ${REGION} ${ENCRYPTED_AMI} ${kms_key_id} "${SHARED_DIR}/aws_ami_compute"
fi
