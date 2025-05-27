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


# ----------------------------------------------------------
# Check if instances match CPMS spec
# https://issues.redhat.com/browse/OCPBUGS-55492
#
# This check is applicable for all CAPI install*
# For now, it will be enabled for 4.19+ only.*
# We will enable the check on the previous versions depending on the backport
#
# C2S/SC2S emulator uses single AZ, skip check for them.
# ----------------------------------------------------------

all_equal() {
  echo "Checking $*"
  local first="$1"
  shift
  for s in "$@"; do
    if [ "$first" != "$s" ]; then
      return 1
    fi
  done
  return 0
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
ocp_major_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1)

if [ -f "${SHARED_DIR}/unset-proxy.sh" ] ; then
  source "${SHARED_DIR}/unset-proxy.sh"
fi

if ((ocp_major_version == 4 && ocp_minor_version >= 19)) && [[ ! "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then

  echo "Check if instances match CPMS spec ... "

  workdir=$(mktemp -d)
  out_machines=${workdir}/machines.json
  out_instances=${workdir}/instances.json
  out_subnets=${workdir}/subnets.json

  if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
  fi

  oc get machines.machine.openshift.io -n openshift-machine-api -ojson > $out_machines

  if [ -f "${SHARED_DIR}/unset-proxy.sh" ] ; then
    source "${SHARED_DIR}/unset-proxy.sh"
  fi

  aws --region $REGION ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" > $out_instances
  vpc_id=$(jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .VpcId' $out_instances | head -n 1)
  aws --region $REGION ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc_id}" > $out_subnets

  count=$(jq '.items|length' $out_machines)
  for i in $(seq 0 $((count-1)));
  do
    # Outputs from Cluster cluster
    c_subnet=$(jq -r --argjson i $i '.items[$i].spec.providerSpec.value.subnet.id' $out_machines)
    c_placement_az=$(jq -r --argjson i $i '.items[$i].spec.providerSpec.value.placement.availabilityZone' $out_machines)
    c_provider_id=$(jq -r --argjson i $i '.items[$i].spec.providerID' $out_machines)
    c_name=$(jq -r --argjson i $i '.items[$i].metadata.name' $out_machines)
    c_role=$(jq -r --argjson i $i '.items[$i].metadata.labels."machine.openshift.io/cluster-api-machine-role"' $out_machines)
    c_zone_label=$(jq -r --argjson i $i '.items[$i].metadata.labels."machine.openshift.io/zone"' $out_machines)
    c_instance_id=$(jq -r --argjson i $i '.items[$i].status.providerStatus.instanceId' $out_machines)

    # Outputs from AWS VPC
    v_subnet_az=$(jq -r --arg s $c_subnet '.Subnets[] | select(.SubnetId==$s) | .AvailabilityZone' $out_subnets)
    v_subnet_azid=$(jq -r --arg s $c_subnet '.Subnets[] | select(.SubnetId==$s) | .AvailabilityZoneId' $out_subnets)

    # Outputs from AWS EC2 Instance
    i_subnet=$(jq -r --arg id $c_instance_id '.Reservations[].Instances[] | select(.InstanceId==$id) | .SubnetId' $out_instances)
    i_placement_az=$(jq -r --arg id $c_instance_id '.Reservations[].Instances[] | select(.InstanceId==$id) | .Placement.AvailabilityZone' $out_instances)


    echo -e "\n--------- ${c_role} / ${c_name}"
    echo -e "** From Cluster cluster"
    echo -e "Name:\t$c_name"
    echo -e "Role:\t$c_role"

    echo -e "Subnet:\t$c_subnet"
    echo -e "Placement AZ:\t$c_placement_az"
    echo -e "Provider ID:\t$c_provider_id"
    echo -e "Label machine.openshift.io/zone:\t$c_zone_label"
    echo -e "Instance ID:\t$c_instance_id"

    echo -e "\n** From AWS VPC: ${c_subnet}"
    echo -e "Subnet AZ:\t$v_subnet_az"
    echo -e "Subnet AZ ID:\t$v_subnet_azid"

    echo -e "\n** From AWS EC2: ${c_instance_id}"
    echo -e "Subnet:\t$i_subnet"
    echo -e "Placement AZ:\t$i_placement_az"

    provider_az=$(echo "${c_provider_id}" | awk -F'/' '{print $4}')

    if ! all_equal "$c_placement_az" "$c_zone_label" "$v_subnet_az" "$i_placement_az" "$provider_az"; then
      ret=$((ret+1))
      echo "FAIL: Instances do NOT match CPMS spec: c_placement_az:$c_placement_az c_zone_label:$c_zone_label v_subnet_az:$v_subnet_az i_placement_az:$i_placement_az provider_az:$provider_az"
    else
      echo "PASS: Instances match CPMS spec."
    fi
  done

else
  echo "Skip instances-CPMS checking for ${ocp_major_version}.${ocp_minor_version}"
fi


exit $ret
