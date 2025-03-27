#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  REGION=$source_region
fi

INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)

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

ret=0

ic_subnets=$(yq-go r -j $CONFIG platform.aws.subnets | jq  -r '.[]')
if [[ $ic_subnets == "" ]]; then
  echo "No byo-subnets found in install config, exit now."
  exit 1
fi

out=${ARTIFACT_DIR}/subnets.json
aws --region ${REGION} ec2 describe-subnets --subnet-ids ${ic_subnets} > $out

# tag: kubernetes.io/cluster/$INFRA_ID: shared
expect_k="kubernetes.io/cluster/$INFRA_ID"
expect_v="shared"
kv_str="[$expect_k:$expect_v]"

echo "--------------------------------"
echo "Subnets in install-config:"
yq-go r ${CONFIG} platform.aws.subnets
echo "--------------------------------"
echo "Subnets contains tag $kv_str:"
jq --arg k $expect_k --arg v $expect_v -r '[.Subnets[] | select(any(.Tags[]; .Key == $k and .Value == $v)) | {subnet: .SubnetId, tags: .Tags}]' $out
echo "--------------------------------"

cnt=$(jq --arg k $expect_k --arg v $expect_v -r '[.Subnets[] | select(any(.Tags[]; .Key == $k and .Value == $v))] | length' $out)
expect_cnt=$(yq-go r ${CONFIG} --length platform.aws.subnets)
if [[ "${cnt}" != "${expect_cnt}" ]]; then
  echo "FAIL: check tag $kv_str, found ${cnt}, but expect ${expect_cnt}, please check following subents:"
  jq --arg k $expect_k --arg v $expect_v -r '[.Subnets[] | select(any(.Tags[]; .Key == $k and .Value == $v) | not) | {subnet: .SubnetId, tags: .Tags}]' $out
  ret=$((ret+1))
else
  echo "PASS: check tag $kv_str"
fi

exit $ret
