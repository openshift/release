#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
VPC_ID=$(cat "${SHARED_DIR}/vpc_id")

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

if (( ocp_minor_version <= 13 && ocp_major_version == 4 )); then
  echo "Custom SG in 4.13- is not applicable, skip now."
  exit 0
fi


# For 4.16+, this SG is reaquired by:
# * RHEL scaleup
# * private cluster, to fetch logs from bastion host
# see https://issues.redhat.com/browse/OCPBUGS-33845 [AWS CAPI install]The source of TCP/22 in master&worker's SG is limited to master&node only
sg_name=${CLUSTER_NAME}-ssh-sg
tag_json=$(mktemp)
cat <<EOF> $tag_json
[
  {
    "ResourceType": "security-group",
    "Tags": [
      {
        "Key": "Name",
        "Value": "${sg_name}"
      }
    ]
  }
]
EOF

sg_id=$(aws ec2 create-security-group --region $REGION --group-name ${sg_name} --vpc-id $VPC_ID \
    --tag-specifications file://${tag_json} \
    --description "Prow CI Test: SG for enabling port 22 inside VPC" | jq -r '.GroupId')
echo $sg_id > ${SHARED_DIR}/security_groups_ids

vpc_cidr=$(aws ec2 describe-vpcs --region $REGION --vpc-ids ${VPC_ID} | jq -r '.Vpcs[0].CidrBlock')

aws ec2 authorize-security-group-ingress --region ${REGION} --group-id ${sg_id} --protocol tcp --port 22 --cidr ${vpc_cidr}
