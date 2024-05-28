#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

if test ! -f "${SHARED_DIR}/aws_bastion_sgs"
then
    echo "No SG appended to bastion, so no action needed"
    exit 0
else
    bastion_security_groups=$(cat "${SHARED_DIR}/aws_bastion_sgs")	
    bastion_instance_id=$(cat "${SHARED_DIR}/aws-instance-ids.txt")
    echo "Removing Worker SG from the bastion"
    aws ec2 modify-instance-attribute --region ${REGION} --instance-id ${bastion_instance_id} --groups ${bastion_security_groups}
fi
