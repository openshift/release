#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

for sg_id in $(cat ${SHARED_DIR}/security_groups_ids); do
    echo "Deleting sg - ${sg_id}... "
    aws --region $REGION ec2 delete-security-group --group-id ${sg_id} 
done
