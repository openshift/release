#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Going to create VPC and related resources..."

workdir="/tmp/installer"
mkdir -p "${workdir}"
pushd "${workdir}"

if ! [ -x "$(command -v aliyun)" ]; then
  echo "$(date -u --rfc-3339=seconds) - Downloading 'aliyun' as it's not intalled..."
  curl -sSL "https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz" --output aliyun-cli-linux-latest-amd64.tgz && \
  tar -xvf aliyun-cli-linux-latest-amd64.tgz && \
  rm -f aliyun-cli-linux-latest-amd64.tgz
  ALIYUN_BIN="${workdir}/aliyun"
else
  ALIYUN_BIN="$(which aliyun)"
fi
echo "$(date -u --rfc-3339=seconds) - 'aliyun version' $(${ALIYUN_BIN} version)"

# copy the creds to the SHARED_DIR
if test -f "${CLUSTER_PROFILE_DIR}/alibabacreds.ini" 
then
  echo "$(date -u --rfc-3339=seconds) - Copying creds from CLUSTER_PROFILE_DIR to SHARED_DIR..."
  cp ${CLUSTER_PROFILE_DIR}/alibabacreds.ini ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/config ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/envvars ${SHARED_DIR}
else
  echo "$(date -u --rfc-3339=seconds) - Copying creds from /var/run/vault/alibaba/ to SHARED_DIR..."
  cp /var/run/vault/alibaba/alibabacreds.ini ${SHARED_DIR}
  cp /var/run/vault/alibaba/config ${SHARED_DIR}
  cp /var/run/vault/alibaba/envvars ${SHARED_DIR}
fi

source ${SHARED_DIR}/envvars

echo "$(date -u --rfc-3339=seconds) - 'aliyun' authentication..."
ALIYUN_PROFILE="${SHARED_DIR}/config"
${ALIYUN_BIN} configure set --config-path "${ALIYUN_PROFILE}"

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
REGION="${LEASED_RESOURCE}"

VPC_CIDR='10.0.0.0/16'
NATGW_FLAG="yes"
if [[ "${RESTRICTED_NETWORK}" == "yes" ]]; then
  NATGW_FLAG="no"
fi

# Get the region's vpc endpoint
aliyun_vpc_endpoint=$(${ALIYUN_BIN} vpc DescribeRegions | jq -c ".Regions.Region[] | select(.RegionId | contains(\"${REGION}\"))" | jq -r .RegionEndpoint)
if [[ -z "${aliyun_vpc_endpoint}" ]]; then
  echo "VPC is not supported in region '${REGION}', abort." && exit 1
fi
# Get the region's ecs endpoint
aliyun_ecs_endpoint=$(${ALIYUN_BIN} ecs DescribeRegions | jq -c ".Regions.Region[] | select(.RegionId | contains(\"${REGION}\"))" | jq -r .RegionEndpoint)

# Get the availability zones for the control-plane nodes's instance type
${ALIYUN_BIN} ecs DescribeAvailableResource --DestinationResource "InstanceType" \
  --RegionId "${REGION}" --IoOptimized "optimized" --InstanceType "${CONTROL_PLANE_INSTANCE_TYPE}" \
  --endpoint "${aliyun_ecs_endpoint}" > out.json
readarray -t ecs1_avail_zones < <(jq -r .AvailableZones.AvailableZone[].ZoneId out.json)

# Get the availability zones for the compute nodes's instance type
if [[ "${CONTROL_PLANE_INSTANCE_TYPE}" != "${COMPUTE_INSTANCE_TYPE}" ]]; then
  ${ALIYUN_BIN} ecs DescribeAvailableResource --DestinationResource "InstanceType" \
    --RegionId "${REGION}" --IoOptimized "optimized" --InstanceType "${COMPUTE_INSTANCE_TYPE}" \
    --endpoint "${aliyun_ecs_endpoint}" > out.json
  readarray -t ecs2_avail_zones < <(jq -r .AvailableZones.AvailableZone[].ZoneId out.json)
fi

# Create VPC
echo "$(date -u --rfc-3339=seconds) - CreateVpc"
${ALIYUN_BIN} vpc CreateVpc --RegionId "${REGION}" --CidrBlock "${VPC_CIDR}" \
  --endpoint "${aliyun_vpc_endpoint}" --VpcName "${CLUSTER_NAME}-vpc" > out.json
sleep 30s
vpc_id=$(jq -r .VpcId out.json)
cat <<EOF > "${SHARED_DIR}/customer_vpc_subnets.yaml"
platform:
  alibabacloud:
    vpcID: ${vpc_id}
    vswitchIDs: 
EOF

${ALIYUN_BIN} vpc ListEnhanhcedNatGatewayAvailableZones --RegionId "${REGION}" \
  --endpoint "${aliyun_vpc_endpoint}" > out.json
readarray -t nat_gateway_avail_zones < <(jq -r .Zones[].ZoneId out.json)

index=240
no_vswitch_cmds=""
no_snat_cmds=""

# Create vSwitches, and NAT gateway if applicable
for the_zone in "${nat_gateway_avail_zones[@]}"; do
  # At most creating 3 vswitches hosting bootstrap/control-plane/compute nodes, i.e.
  # A.B.240.0/20, A.B.224.0/20, and A.B.208.0/20
  [ ${index} -le 192 ] && break

  if ! echo "${ecs1_avail_zones[@]}" | grep -w -q "${the_zone}"; then
    echo "Skip the zone '${the_zone}' as the control-plane instance type is not supported." && continue
  fi
  if [[ "${CONTROL_PLANE_INSTANCE_TYPE}" != "${COMPUTE_INSTANCE_TYPE}" ]] && ! echo "${ecs2_avail_zones[@]}" | grep -w -q "${the_zone}"; then
    echo "Skip the zone '${the_zone}' as the compute instance type is not supported." && continue
  fi

  # Configure NAT gateway in the first available zone
  if [ X"${NATGW_FLAG}" == X"yes" ] && [ ${index} -eq 240 ]; then
    echo "$(date -u --rfc-3339=seconds) - Configure NAT gateway in the first available zone"

    echo "$(date -u --rfc-3339=seconds) - AllocateEipAddress"
    ${ALIYUN_BIN} vpc AllocateEipAddress --RegionId "${REGION}" --InternetChargeType "PayByTraffic" \
    --Bandwidth 200 --endpoint "${aliyun_vpc_endpoint}" > out.json
    eip_id=$(jq -r '.AllocationId' out.json)
    eip_addr=$(jq -r '.EipAddress' out.json)

    sleep 5s
    echo "$(date -u --rfc-3339=seconds) - CreateVSwitch"
    ${ALIYUN_BIN} vpc CreateVSwitch --RegionId "${REGION}" --VpcId "${vpc_id}" --ZoneId "${the_zone}" \
      --CidrBlock "10.0.192.0/20" --endpoint "${aliyun_vpc_endpoint}" \
      --VSwitchName "${CLUSTER_NAME}-vswitch-natgw" > out.json
    vswitch_id=$(jq -r .VSwitchId out.json)
    no_vswitch_cmds="${no_vswitch_cmds}\n${ALIYUN_BIN} vpc DeleteVSwitch --RegionId ${REGION} --VSwitchId ${vswitch_id} --endpoint ${aliyun_vpc_endpoint}"

    sleep 10s
    echo "$(date -u --rfc-3339=seconds) - CreateNatGateway"
    ${ALIYUN_BIN} vpc CreateNatGateway --RegionId "${REGION}" --VpcId "${vpc_id}" --NatType "Enhanced" \
      --Spec "Small" --InternetChargeType "PayByLcu" --endpoint "${aliyun_vpc_endpoint}" \
      --VSwitchId "${vswitch_id}" > out.json
    natgw_id=$(jq -r '.NatGatewayId' out.json)
    natgw_snat_table_id=$(jq -r '.SnatTableIds.SnatTableId[0]' out.json)

    sleep 90s
    echo "$(date -u --rfc-3339=seconds) - AssociateEipAddress"
    ${ALIYUN_BIN} vpc AssociateEipAddress --RegionId "${REGION}" --AllocationId "${eip_id}" \
      --InstanceType "Nat" --InstanceId "${natgw_id}" --endpoint "${aliyun_vpc_endpoint}"
    sleep 90s
  fi

  sleep 5s
  echo "$(date -u --rfc-3339=seconds) - CreateVSwitch"
  ${ALIYUN_BIN} vpc CreateVSwitch --RegionId "${REGION}" --VpcId "${vpc_id}" --ZoneId "${the_zone}" \
    --CidrBlock "10.0.${index}.0/20" --endpoint "${aliyun_vpc_endpoint}" \
    --VSwitchName "${CLUSTER_NAME}-vswitch-${the_zone}" > out.json
  index=$((${index} - 16))
  vswitch_id=$(jq -r .VSwitchId out.json)
  cat <<EOF >> "${SHARED_DIR}/customer_vpc_subnets.yaml"
    - ${vswitch_id}
EOF
  no_vswitch_cmds="${no_vswitch_cmds}\n${ALIYUN_BIN} vpc DeleteVSwitch --RegionId ${REGION} --VSwitchId ${vswitch_id} --endpoint ${aliyun_vpc_endpoint}"

  if [ X"${NATGW_FLAG}" == X"yes" ]; then
    sleep 5s
    echo "$(date -u --rfc-3339=seconds) - CreateSnatEntry"
    ${ALIYUN_BIN} vpc CreateSnatEntry --RegionId "${REGION}" --endpoint "${aliyun_vpc_endpoint}" \
      --SnatIp "${eip_addr}" --SnatTableId "${natgw_snat_table_id}" \
      --SourceVSwitchId "${vswitch_id}" > out.json
    snat_id=$(jq -r .SnatEntryId out.json)
    no_snat_cmds="${no_snat_cmds}\n${ALIYUN_BIN} vpc DeleteSnatEntry --SnatEntryId ${snat_id} --SnatTableId ${natgw_snat_table_id} --RegionId ${REGION} --endpoint ${aliyun_vpc_endpoint}"
  fi
done

if [ X"${NATGW_FLAG}" == X"yes" ]; then
  cat <<EOF >"${SHARED_DIR}/destroy-vpc.sh"
$(echo -e ${no_snat_cmds})
sleep 60s
${ALIYUN_BIN} vpc UnassociateEipAddress --RegionId ${REGION} --AllocationId ${eip_id} --InstanceType 'Nat' --InstanceId ${natgw_id} --endpoint ${aliyun_vpc_endpoint}
sleep 90s
${ALIYUN_BIN} vpc ReleaseEipAddress --AllocationId ${eip_id} --RegionId ${REGION} --endpoint ${aliyun_vpc_endpoint}
sleep 60s
${ALIYUN_BIN} vpc DeleteNatGateway --NatGatewayId ${natgw_id} --Force true --RegionId ${REGION} --endpoint ${aliyun_vpc_endpoint}
sleep 120s
EOF
fi

cat <<EOF >>"${SHARED_DIR}/destroy-vpc.sh"
$(echo -e ${no_vswitch_cmds})
sleep 30s
${ALIYUN_BIN} vpc DeleteVpc --RegionId ${REGION} --VpcId ${vpc_id} --endpoint ${aliyun_vpc_endpoint}
EOF

popd
rm -rf "${workdir}"

[ ${index} -eq 240 ] && echo "Failed to find any zone in region '${REGION}' for the given instance types (${CONTROL_PLANE_INSTANCE_TYPE} ${COMPUTE_INSTANCE_TYPE}), abort." && exit 1

echo "$(date -u --rfc-3339=seconds) - Done creating VPC."
