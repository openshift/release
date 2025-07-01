#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'delete_all' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

function delete_ami()
{
    local ami_file=$1
    local ami_id
    if [ ! -f "${ami_file}" ]; then
        echo "Error: Not found ${ami_file} file, please check"
        return 1
    fi

    ami_id=$(< "${ami_file}")
    echo "Deleting ${ami_id} and its snapshots"
    aws --region ${REGION} ec2 deregister-image --image-id ${ami_id} --delete-associated-snapshots
    echo "Done"
}

function delete_all()
{
    set +e
    if [[ "${ENABLE_AWS_AMI_DEFAULT_MACHINE}" == "yes" ]]; then
        delete_ami "${SHARED_DIR}/aws_ami"
    fi

    if [[ "${ENABLE_AWS_AMI_CONTROL_PLANE}" == "yes" ]]; then
        delete_ami "${SHARED_DIR}/aws_ami_control_plane"
    fi

    if [[ "${ENABLE_AWS_AMI_COMPUTE}" == "yes" ]]; then
        delete_ami "${SHARED_DIR}/aws_ami_compute"
    fi
}
