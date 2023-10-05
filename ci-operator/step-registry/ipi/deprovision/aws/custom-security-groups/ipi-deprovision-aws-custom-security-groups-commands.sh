#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if test ! -f "${SHARED_DIR}/security_groups"
then
  echo "No security group file found, so unable to tear down."
  exit 0
fi

REGION="${LEASED_RESOURCE}"
aws ec2 delete-security-group --region ${REGION} --group-id "$(cat ${SHARED_DIR}/security_groups)" & 
wait "$!"
