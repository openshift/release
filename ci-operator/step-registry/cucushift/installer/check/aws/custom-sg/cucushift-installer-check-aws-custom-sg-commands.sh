#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ ! -f ${SHARED_DIR}/security_groups_ids ]]; then
    echo "No custom SG was created, exit now."
    exit 1
fi


REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

ret=0

if [[ "${ENABLE_CUSTOM_SG_DEFAULT_MACHINE}" == "true" || "${ENABLE_CUSTOM_SG_CONTROL_PLANE}" == "true" ]]; then

    echo "Custom security group enabled on control planes, check the SG attched to control plane"
    # get SG from one of the masters
    control_plane_sgs=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-master*" | jq -r '.Reservations[0].Instances[].NetworkInterfaces[].Groups[].GroupId')

    for sg_id in $(cat ${SHARED_DIR}/security_groups_ids); do
        if [[ ${control_plane_sgs} =~ ${sg_id} ]]; then
           echo "PASS: custom security group ${sg_id} was found on control plane"
        else
           echo "FAIL: custom security group ${sg_id} was NOT found on control plane"
           ret=$((ret + 1))
        fi
    done
fi

if [[ "${ENABLE_CUSTOM_SG_DEFAULT_MACHINE}" == "true" || "${ENABLE_CUSTOM_SG_CUMPUTE}" == "true" ]]; then

    echo "Custom security group enabled on workers, check the SG attched to the nodes"
    # get SG from one of the nodes
    compute_sgs=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-worker*" | jq -r '.Reservations[0].Instances[].NetworkInterfaces[].Groups[].GroupId')

    for sg_id in $(cat ${SHARED_DIR}/security_groups_ids); do
        if [[ ${compute_sgs} =~ ${sg_id} ]]; then
           echo "PASS: custom security group ${sg_id} was found on compute node"
        else
           echo "FAIL: custom security group ${sg_id} was NOT found on commpute node"
           ret=$((ret + 1))
        fi
    done
fi

exit $ret
