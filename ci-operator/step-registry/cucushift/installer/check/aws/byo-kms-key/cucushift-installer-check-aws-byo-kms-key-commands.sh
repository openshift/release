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


REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
CONFIG=${SHARED_DIR}/install-config.yaml
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"


function is_empty()
{
    local v="$1"
    if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
        return 0
    fi
    return 1
}

ret=0

echo "-------------------------------------------------------------"
echo "Default EC2 KMS key on $REGION"
echo "-------------------------------------------------------------"

# default KMS key used by EC2
default_kms_key_id=$(aws --region $REGION ec2 get-ebs-default-kms-key-id | jq -r '.KmsKeyId')
default_kms_key_arn=$(aws --region $REGION kms describe-key --key-id ${default_kms_key_id} | jq -r '.KeyMetadata.Arn')

function show_key()
{
  local k=${1:-}

  if [[ "${k}" == "${default_kms_key_arn}" ]]; then
    k="$k (default key)"
  fi
  echo $k | awk -F'/' '{print $2}'
}

show_key "${default_kms_key_arn}"

echo "-------------------------------------------------------------"
echo "KMS keys used by cluster"
echo "-------------------------------------------------------------"

control_plane_vols=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" "Name=tag:Name,Values=*master*" \
    | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId')

compute_vols=$(aws ec2 describe-instances --region $REGION --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" "Name=tag:Name,Values=*worker*" \
    | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId')

echo "controlPlane volumes:"
echo "${control_plane_vols}"
echo "compute volumes:"
echo "${compute_vols}"

aws ec2 describe-volumes --region $REGION --volume-ids ${control_plane_vols} > ${ARTIFACT_DIR}/control_plane_vols.json
aws ec2 describe-volumes --region $REGION --volume-ids ${compute_vols} > ${ARTIFACT_DIR}/compute_vols.json
control_plane_kms_key=$(cat ${ARTIFACT_DIR}/control_plane_vols.json | jq -r '.Volumes[].KmsKeyId' | sort | uniq)

# Keys used by cumpute node
compute_kms_key=$(cat ${ARTIFACT_DIR}/compute_vols.json | jq -r '.Volumes[] | select(any(.Tags[]; .Key == "Name" and (.Value | contains("worker")))) | .KmsKeyId' | sort | uniq)

# Keys used by the volumes created by ipi-install-monitoringpvc (should be the default KMS key)
# "Key": "Name",
# "Value": "ci-op-f59tc36y-a3cdc-vxf25-dynamic-pvc-9d10a326-ec97-42f0-88c9-6e3f0c65402d"
pvc_kms_key=$(cat ${ARTIFACT_DIR}/compute_vols.json | jq -r '.Volumes[] | select(any(.Tags[]; .Key == "Name" and (.Value | contains("dynamic-pvc")))) | .KmsKeyId' | sort | uniq)

echo "controlPlane keys: $(show_key "${control_plane_kms_key}")"
echo "compute keys: $(show_key "${compute_kms_key}")"
echo "pvc keys: $(show_key "${pvc_kms_key}")"


echo "-------------------------------------------------------------"
echo "KMS keys configured in install-config.yaml"
echo "-------------------------------------------------------------"

ic_platform_key=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.rootVolume.kmsKeyARN')
ic_control_plane_key=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.rootVolume.kmsKeyARN')
ic_compute_key=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.rootVolume.kmsKeyARN')

echo "platform: $(show_key "${ic_platform_key}")"
echo "controlPlane: $(show_key "${ic_control_plane_key}")"
echo "compute: $(show_key "${ic_compute_key}")"



echo "-------------------------------------------------------------"
echo "Expected keys"
echo "-------------------------------------------------------------"

expected_control_plane_key="${default_kms_key_arn}"
expected_compute_key="${default_kms_key_arn}"

if ! is_empty "$ic_platform_key"; then
  echo "platform.aws.defaultMachinePlatform.rootVolume.kmsKeyARN was found: $(show_key "${ic_platform_key}")"
  expected_control_plane_key="${ic_platform_key}"
  expected_compute_key="${ic_platform_key}"
fi

if ! is_empty "$ic_control_plane_key"; then
  echo "controlPlane.platform.aws.rootVolume.kmsKeyARN was found: $(show_key "${ic_control_plane_key}")"
  expected_control_plane_key="${ic_control_plane_key}"
fi

if ! is_empty "$ic_compute_key"; then
  echo "compute[0].platform.aws.rootVolume.kmsKeyARN was found: $(show_key "${ic_compute_key}")"
  expected_compute_key="${ic_compute_key}"
fi

echo "expected_control_plane_key: $(show_key "${expected_control_plane_key}")"
echo "expected_compute_key: $(show_key "${expected_compute_key}")"


echo "-------------------------------------------------------------"
echo "Checking"
echo "-------------------------------------------------------------"

if [[ "${control_plane_kms_key}" != "${expected_control_plane_key}" ]]; then
  echo "FAIL: KMS key: control plane node: expect: $(show_key "${expected_control_plane_key}"), current: $(show_key "${control_plane_kms_key}")"
  ret=$((ret+1))
else
  echo "PASS: KMS key: control plane node: $(show_key "${expected_control_plane_key}")"
fi

if [[ "${compute_kms_key}" != "${expected_compute_key}" ]]; then
  echo "FAIL: KMS key: compute node: expect: $(show_key "${expected_compute_key}"), current: $(show_key "${compute_kms_key}")"
  ret=$((ret+1))
else
  echo "PASS: KMS key: compute node: $(show_key "${expected_compute_key}")"
fi

if ! is_empty "$ic_platform_key"; then
  ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
  if (( ocp_minor_version < 13 )); then
    echo "Skip: KMS key: PVC: default storage class is only available on 4.13+, skip checking."
  else
    if [[ "${pvc_kms_key}" != "${ic_platform_key}" ]]; then
      echo "FAIL: KMS key: PVC: expect: $(show_key "${ic_platform_key}"), current: $(show_key "${pvc_kms_key}")"
      ret=$((ret+1))
    else
      echo "PASS: KMS key: PVC: $(show_key "${pvc_kms_key}")"
    fi
  fi
else
  echo "Skip: KMS key: PVC: Default platform key is not configured, skip checking."
fi

exit $ret
