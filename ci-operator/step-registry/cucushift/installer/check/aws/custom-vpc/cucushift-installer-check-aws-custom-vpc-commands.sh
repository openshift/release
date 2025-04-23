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

function get_subnets()
{
  if [ "$(yq-v4 e '.platform.aws.subnets // ""' "$CONFIG")" != "" ]; then
    yq-v4 e -ojson '.platform.aws.subnets' "$CONFIG" | jq -r '.[]'
  elif [ "$(yq-v4 e '.platform.aws.vpc.subnets // ""' "$CONFIG")" != "" ]; then
    yq-v4 e -ojson '.platform.aws.vpc.subnets' "$CONFIG" | jq -r '.[].id'
  else
    echo ""
  fi
}

ic_subnets=$(get_subnets)
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
echo ".platform.aws in install-config:"
yq-v4 e '.platform.aws' "$CONFIG"
echo "--------------------------------"
echo "Subnets contains tag $kv_str:"
jq --arg k $expect_k --arg v $expect_v -r '[.Subnets[] | select(any(.Tags[]; .Key == $k and .Value == $v)) | {subnet: .SubnetId, tags: .Tags}]' $out
echo "--------------------------------"

cnt=$(jq --arg k $expect_k --arg v $expect_v -r '[.Subnets[] | select(any(.Tags[]; .Key == $k and .Value == $v))] | length' $out)
expect_cnt=$(echo ${ic_subnets} | wc -w)
if [[ "${cnt}" != "${expect_cnt}" ]]; then
  echo "FAIL: check tag $kv_str, found ${cnt}, but expect ${expect_cnt}, please check following subents:"
  jq --arg k $expect_k --arg v $expect_v -r '[.Subnets[] | select(any(.Tags[]; .Key == $k and .Value == $v) | not) | {subnet: .SubnetId, tags: .Tags}]' $out
  ret=$((ret+1))
else
  echo "PASS: check tag $kv_str"
fi


# AWS - Allocate Load Balancers (API & Ingress) to Specific Subnets https://issues.redhat.com/browse/OCPSTRAT-569
function subnets_by_role()
{
    local role=$1
    yq-v4 e -ojson '.platform.aws.vpc' ${CONFIG} | jq -r --arg role $role '.subnets | map(select(.roles[].type == $role) | .id) | sort | join(" ")'
}

if [[ ${ASSIGN_ROLES_TO_SUBNETS} == "yes" ]]; then
  #
  # IngressControllerLB
  #
  echo "Checking subnet roles: IngressControllerLB"

  if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
  fi

  ingress_lb_hostname=$(oc -n openshift-ingress get service router-default -o json | jq -r '.status.loadBalancer.ingress[].hostname')

  if [ -f "${SHARED_DIR}/unset-proxy.sh" ] ; then
    source "${SHARED_DIR}/unset-proxy.sh"
  fi

  ingress_lb_output=$(mktemp)
  aws --region ${REGION} elb describe-load-balancers | jq -r --arg lb $ingress_lb_hostname '.LoadBalancerDescriptions[] | select(.DNSName == $lb)' > ${ingress_lb_output}
  
  # ingress_lb_name=$(jq -r '.LoadBalancerName' $ingress_lb_output)
  ingress_lb_subnets=$(jq -r '.Subnets | sort | join(" ")' $ingress_lb_output)
  ic_ingress_lb_subnets=$(subnets_by_role "IngressControllerLB")

  echo "ingress_lb_subnets: $ingress_lb_subnets"
  echo "ic_ingress_lb_subnets: $ic_ingress_lb_subnets"
  if [[ "${ingress_lb_subnets}" == "${ic_ingress_lb_subnets}" ]]; then
    echo "PASS: IngressControllerLB"
  else
    echo "FAIL: IngressControllerLB, please check ingress_lb_output.json"
    cp $ingress_lb_output ${ARTIFACT_DIR}/ingress_lb_output.json
    ret=$((ret+1))
  fi

  #
  # ControlPlaneExternalLB (for public cluster only)
  #
  if [[ "$(yq-v4 e '.publish' "$CONFIG")" != "Internal" ]]; then
    echo "Checking subnet roles: ControlPlaneExternalLB"
    api_lb_ext_name=${INFRA_ID}-ext
    api_lb_ext_output=$(mktemp)
    aws --region ${REGION} elbv2 describe-load-balancers --names ${api_lb_ext_name} > ${api_lb_ext_output}

    api_lb_ext_subnets=$(jq -r '.LoadBalancers[0].AvailabilityZones | map(.SubnetId) | sort | join(" ")' ${api_lb_ext_output})
    ic_api_lb_ext_subnets=$(subnets_by_role "ControlPlaneExternalLB")
    
    echo "api_lb_ext_subnets: $api_lb_ext_subnets"
    echo "ic_api_lb_ext_subnets: $ic_api_lb_ext_subnets"
    if [[ "${api_lb_ext_subnets}" == "${ic_api_lb_ext_subnets}" ]]; then
      echo "PASS: ControlPlaneExternalLB"
    else
      echo "FAIL: ControlPlaneExternalLB, please check api_lb_ext_output.json"
      cp $api_lb_ext_output ${ARTIFACT_DIR}/api_lb_ext_output.json
      ret=$((ret+1))
    fi
  else
    echo "This is a private cluster, skip ControlPlaneExternalLB checking."
  fi

  #
  # ControlPlaneInternalLB
  #
  echo "Checking subnet roles: ControlPlaneInternalLB"
  api_lb_int_name=${INFRA_ID}-int
  api_lb_int_output=$(mktemp)
  aws --region ${REGION} elbv2 describe-load-balancers --names ${api_lb_int_name} > ${api_lb_int_output}

  api_lb_int_subnets=$(jq -r '.LoadBalancers[0].AvailabilityZones | map(.SubnetId) | sort | join(" ")' ${api_lb_int_output})
  ic_api_lb_int_subnets=$(subnets_by_role "ControlPlaneInternalLB")
  
  echo "api_lb_int_subnets: $api_lb_int_subnets"
  echo "ic_api_lb_int_subnets: $ic_api_lb_int_subnets"
  if [[ "${api_lb_int_subnets}" == "${ic_api_lb_int_subnets}" ]]; then
    echo "PASS: ControlPlaneInternalLB"
  else
    echo "FAIL: ControlPlaneInternalLB, please check api_lb_int_output.json"
    cp $api_lb_int_output ${ARTIFACT_DIR}/api_lb_int_output.json
    ret=$((ret+1))
  fi

  #
  # ClusterNode
  #
  echo "Checking subnet roles: ClusterNode"
  instance_output=$(mktemp)
  aws --region ${REGION} ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" > ${instance_output}

  subnets_az=$(jq -r '[.Reservations[].Instances[] | select(.Tags[]? | .Key == "Name" and ((.Value | contains("-master-")) or (.Value | contains("-worker-")))) | .NetworkInterfaces[].SubnetId] | unique | sort | join(" ")' ${instance_output})
  ic_subnets_az=$(subnets_by_role "ClusterNode")

  echo "subnets_az: $subnets_az"
  echo "ic_subnets_az: $ic_subnets_az"
  if [[ "${subnets_az}" == "${ic_subnets_az}" ]]; then
    echo "PASS: ClusterNode"
  else
    echo "FAIL: ClusterNode, please check instance_output.json"
    cp $instance_output ${ARTIFACT_DIR}/instance_output.json
    ret=$((ret+1))
  fi

  #
  # EdgeNode
  #
  if [[ ${ENABLE_AWS_EDGE_ZONE} == "yes" ]]; then
    subnets_edge=$(jq -r '[.Reservations[].Instances[] | select(.Tags[]? | .Key == "Name" and (.Value | contains("-edge-"))) | .NetworkInterfaces[].SubnetId] | unique | sort | join(" ")' ${instance_output})
    ic_subnets_edge=$(subnets_by_role "EdgeNode")

    echo "subnets_edge: $subnets_edge"
    echo "ic_subnets_edge: $ic_subnets_edge"
    if [[ "${subnets_edge}" == "${ic_subnets_edge}" ]]; then
      echo "PASS: EdgeNode"
    else
      echo "FAIL: EdgeNode, please check instance_output.json"
      if [ ! -f "${ARTIFACT_DIR}/instance_output.json" ]; then
        cp $instance_output ${ARTIFACT_DIR}/instance_output.json
      fi
      ret=$((ret+1))
    fi
  fi
fi

exit $ret
