#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

CONFIG=${SHARED_DIR}/install-config.yaml
if [ ! -f "${CONFIG}" ] ; then
  echo "No install-config.yaml found, exit now"
  exit 1
fi


case "${OCP_ARCH}" in
amd64)
    ARCH="x86_64"
    ;;
arm64)
    ARCH="aarch64"
    ;;
*)
    echo "${OCP_ARCH} is not supported, exit now"
    exit 1
esac

default_ami=$(openshift-install coreos print-stream-json | jq -r --arg a $ARCH --arg r $REGION '.architectures[$a].images.aws.regions[$r].image')
echo "AMI (default, \"openshift-install coreos print-stream-json\"): ${default_ami}"

control_plane_ami=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" "Name=tag:Name,Values=*master*" --output json | jq -r '.Reservations[].Instances[].ImageId' | sort | uniq)
compute_ami=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" "Name=tag:Name,Values=*worker*" --output json | jq -r '.Reservations[].Instances[].ImageId' | sort | uniq)
echo "AMI used by cluster: controlPlane: [${control_plane_ami}], compute: [${compute_ami}]"

ret=0

ic_platform_ami=$(yq-go r "${CONFIG}" 'platform.aws.amiID')
ic_control_plane_ami=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.amiID')
ic_compute_ami=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.amiID')
echo "AMI in install-config: platform: [${ic_platform_ami}], controlPlane: [${ic_control_plane_ami}], compute: [${ic_compute_ami}]"


if [[ "${ic_platform_ami}" != "" ]] && [[ "${ic_platform_ami}" != "null" ]]; then
    # custom ami
    if [[ "${control_plane_ami}" != "${ic_platform_ami}" ]] || [[ "${compute_ami}" != "${ic_platform_ami}" ]]; then
        echo "FAIL: Platform AMI mismatch:"
        echo -e "\tCurrent: controlPlane: [${control_plane_ami}], compute: [${compute_ami}]"
        echo -e "\tExpect: [${ic_platform_ami}]"
        ret=$((ret+1))
    else
        echo "PASS: Platform AMI (custom)"
    fi
else
    echo "SKIP: Platform AMI is not set"
fi

if [[ "${ic_control_plane_ami}" != "" ]] && [[ "${ic_control_plane_ami}" != "null" ]]; then
    if [[ "${control_plane_ami}" != "${ic_control_plane_ami}" ]]; then
        echo "FAIL: controlPlane AMI mismatch:"
        echo -e "\tCurrent: [${control_plane_ami}]"
        echo -e "\tExpect:  [${ic_platform_ami}]"
        ret=$((ret+1))
    else
        echo "PASS: controlPlane AMI (custom)"
    fi
else
    echo "SKIP: controlPlane AMI is not set"
fi


if [[ "${ic_compute_ami}" != "" ]] && [[ "${ic_compute_ami}" != "null" ]]; then
    # custom ami
    if [[ "${compute_ami}" != "${ic_compute_ami}" ]]; then
        echo "FAIL: Compute AMI mismatch:"
        echo -e "\tCurrent: [${compute_ami}]"
        echo -e "\tExpect:  [${ic_compute_ami}]"
        ret=$((ret+1))
    else
        echo "PASS: Compute AMI (custom)"
    fi
else
    echo "SKIP: Compute AMI is not set"
fi

exit $ret
