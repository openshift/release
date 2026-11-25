#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"

if [[ ! -f "${bastion_ignition_file}" ]]; then
  echo "'${bastion_ignition_file}' not found, abort." && exit 1
fi

vpc_config_yaml="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [[ -z "${VPC_ID}" ]] && [[ ! -s "${vpc_config_yaml}" ]]; then
  echo "Lack of VPC info, abort." && exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Going to create bastion host..."

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

#####################################
##############Initialize#############
#####################################

# copy the creds to the SHARED_DIR
if test -f "${CLUSTER_PROFILE_DIR}/alibabacreds.ini" 
then
  echo "$(date -u --rfc-3339=seconds) - Copying creds from CLUSTER_PROFILE_DIR to SHARED_DIR..."
  cp ${CLUSTER_PROFILE_DIR}/alibabacreds.ini ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/config ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/envvars ${SHARED_DIR}
  cp ${CLUSTER_PROFILE_DIR}/ssh-privatekey ${SHARED_DIR}
else
  echo "$(date -u --rfc-3339=seconds) - Copying creds from /var/run/vault/alibaba/ to SHARED_DIR..."
  cp /var/run/vault/alibaba/alibabacreds.ini ${SHARED_DIR}
  cp /var/run/vault/alibaba/config ${SHARED_DIR}
  cp /var/run/vault/alibaba/envvars ${SHARED_DIR}
  cp /var/run/vault/alibaba/ssh-privatekey ${SHARED_DIR}
fi

source ${SHARED_DIR}/envvars

echo "$(date -u --rfc-3339=seconds) - 'aliyun' authentication..."
ALIYUN_PROFILE="${SHARED_DIR}/config"
${ALIYUN_BIN} configure set --config-path "${ALIYUN_PROFILE}"

bastion_name_suffix="bastion"
bastion_user_data=$(cat "${bastion_ignition_file}" | base64 -w0)
echo "$(date -u --rfc-3339=seconds) - Fedora CoreOS Image ID: ${IMAGE_ID} "

REGION="${LEASED_RESOURCE}"
echo "$(date -u --rfc-3339=seconds) - Using region: ${REGION}"

if [[ -z "${VPC_ID}" ]]; then
  VPC_ID=$(yq-go r "${vpc_config_yaml}" 'platform.alibabacloud.vpcID')
fi
if [[ -z "${VPC_ID}" ]]; then
  echo "Could not find VPC network" && exit 1
fi

#####################################
##########Create Bastion#############
#####################################

disk_type='cloud_essd'
instance_type='ecs.g6.large'

aliyun_ecs_endpoint=$(${ALIYUN_BIN} ecs DescribeRegions | jq -c ".Regions.Region[] | select(.RegionId | contains(\"${REGION}\"))" | jq -r .RegionEndpoint)
aliyun_vpc_endpoint=$(${ALIYUN_BIN} vpc DescribeRegions | jq -c ".Regions.Region[] | select(.RegionId | contains(\"${REGION}\"))" | jq -r .RegionEndpoint)

avail_zone=$(${ALIYUN_BIN} ecs DescribeAvailableResource --DestinationResource 'InstanceType' --RegionId "${REGION}" --IoOptimized 'optimized' --InstanceType "${instance_type}" --endpoint "${aliyun_ecs_endpoint}" | jq -r .AvailableZones.AvailableZone[0].ZoneId)
echo "$(date -u --rfc-3339=seconds) - CreateVSwitch"
${ALIYUN_BIN} vpc CreateVSwitch \
  --VpcId "${VPC_ID}" \
  --RegionId "${REGION}" \
  --ZoneId "${avail_zone}" \
  --CidrBlock "10.0.176.0/20" \
  --endpoint "${aliyun_vpc_endpoint}" \
  --VSwitchName "${CLUSTER_NAME}-${bastion_name_suffix}" > out.json
vswitch_id=$(jq -r .VSwitchId out.json)

echo "$(date -u --rfc-3339=seconds) - CreateSecurityGroup and then AuthorizeSecurityGroup"
${ALIYUN_BIN} ecs CreateSecurityGroup \
  --RegionId "${REGION}" \
  --VpcId "${VPC_ID}" \
  --endpoint "${aliyun_ecs_endpoint}" \
  --SecurityGroupName "${CLUSTER_NAME}-${bastion_name_suffix}" > out.json
sg_id=$(jq -r .SecurityGroupId out.json)
${ALIYUN_BIN} ecs AuthorizeSecurityGroup \
  --RegionId "${REGION}" \
  --SecurityGroupId "${sg_id}" \
  --IpProtocol "tcp" \
  --PortRange "22/22" \
  --SourceCidrIp "0.0.0.0/0" \
  --endpoint "${aliyun_ecs_endpoint}"
${ALIYUN_BIN} ecs AuthorizeSecurityGroup \
  --RegionId "${REGION}" \
  --SecurityGroupId "${sg_id}" \
  --IpProtocol "tcp" \
  --PortRange "3128/3129" \
  --SourceCidrIp "0.0.0.0/0" \
  --endpoint "${aliyun_ecs_endpoint}"
${ALIYUN_BIN} ecs AuthorizeSecurityGroup \
  --RegionId "${REGION}" \
  --SecurityGroupId "${sg_id}" \
  --IpProtocol "tcp" \
  --PortRange "5000/5000" \
  --SourceCidrIp "0.0.0.0/0" \
  --endpoint "${aliyun_ecs_endpoint}"
${ALIYUN_BIN} ecs AuthorizeSecurityGroup \
  --RegionId "${REGION}" \
  --SecurityGroupId "${sg_id}" \
  --IpProtocol "tcp" \
  --PortRange "6001/6002" \
  --SourceCidrIp "0.0.0.0/0" \
  --endpoint "${aliyun_ecs_endpoint}"
${ALIYUN_BIN} ecs AuthorizeSecurityGroup \
  --RegionId "${REGION}" \
  --SecurityGroupId "${sg_id}" \
  --IpProtocol "tcp" \
  --PortRange "873/873" \
  --SourceCidrIp "0.0.0.0/0" \
  --endpoint "${aliyun_ecs_endpoint}"
 
sleep 30s
echo "$(date -u --rfc-3339=seconds) - Launching Fedora CoreOS bastion VM..."
${ALIYUN_BIN} ecs RunInstances \
  --HostName "${CLUSTER_NAME}-${bastion_name_suffix}" \
  --InstanceName "${CLUSTER_NAME}-${bastion_name_suffix}" \
  --InstanceType "${instance_type}" \
  --RegionId "${REGION}" \
  --ImageId "${IMAGE_ID} " \
  --IoOptimized "optimized" \
  --UserData "${bastion_user_data}" \
  --InternetMaxBandwidthOut 100 \
  --SystemDisk.Category "${disk_type}" \
  --VSwitchId "${vswitch_id}" \
  --SecurityGroupId "${sg_id}" \
  --endpoint "${aliyun_ecs_endpoint}" > out.json
instance_id=$(jq -r .InstanceIdSets.InstanceIdSet[0] out.json)

sleep 60s
echo "$(date -u --rfc-3339=seconds) - DescribeInstances"
${ALIYUN_BIN} ecs DescribeInstances \
  --RegionId "${REGION}" \
  --InstanceName "${CLUSTER_NAME}-${bastion_name_suffix}" \
  --endpoint "${aliyun_ecs_endpoint}" > out.json
bastion_public_ip=$(jq -r .Instances.Instance[].PublicIpAddress.IpAddress[0] out.json)
bastion_private_ip=$(jq -r .Instances.Instance[].NetworkInterfaces.NetworkInterface[0].PrimaryIpAddress out.json)

echo "core" > "${SHARED_DIR}/bastion_ssh_user"

src_proxy_creds_file="/var/run/vault/proxy/proxy_creds"
proxy_credential=$(cat "${src_proxy_creds_file}")
proxy_public_url="http://${proxy_credential}@${bastion_public_ip}:3128"
proxy_private_url="http://${proxy_credential}@${bastion_private_ip}:3128"
echo "${proxy_public_url}" > "${SHARED_DIR}/proxy_public_url"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_public_ip}" >> "${SHARED_DIR}/proxyip"

echo "$(date -u --rfc-3339=seconds) - ssh to the bastion host and then reboot it"
# Workaround of bug https://github.com/coreos/bugs/issues/1291
ssh_private_key="${SHARED_DIR}/ssh-privatekey"
chmod 600 "${ssh_private_key}"
ssh -o StrictHostKeyChecking=no -i "${ssh_private_key}" core@"${bastion_public_ip}" "sudo rm -f /etc/machine-id; sudo reboot"
sleep 60s

cat <<EOF >>"${SHARED_DIR}/destroy-bastion.sh"
sleep 30s
${ALIYUN_BIN} ecs DeleteInstance --InstanceId ${instance_id} --Force true --endpoint ${aliyun_ecs_endpoint}
sleep 30s
${ALIYUN_BIN} ecs DeleteSecurityGroup --RegionId ${REGION} --SecurityGroupId ${sg_id} --endpoint ${aliyun_ecs_endpoint}
${ALIYUN_BIN} vpc DeleteVSwitch --RegionId ${REGION} --VSwitchId ${vswitch_id} --endpoint ${aliyun_vpc_endpoint}
sleep 30s
EOF

if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
  bastion_public_dns="${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}"

  echo "Configuring public DNS for the mirror registry..."
  ${ALIYUN_BIN} alidns AddDomainRecord \
    --DomainName "${BASE_DOMAIN}" \
    --RR "${CLUSTER_NAME}.mirror-registry" \
    --Value "${bastion_public_ip}" \
    --Type A \
    --TTL 600 > out.json
  pub_record_id=$(jq -r .RecordId out.json)
  cat <<EOF >"${SHARED_DIR}/destroy-mirror-dns.sh"
${ALIYUN_BIN} alidns DeleteDomainRecord --RecordId "${pub_record_id}"
EOF
            
  echo "Configuring private DNS for the mirror registry..."
  aliyun_pvtz_endpoint="pvtz.aliyuncs.com"
  ${ALIYUN_BIN} pvtz AddZone \
    --ZoneName "mirror-registry.${BASE_DOMAIN}" \
    --endpoint "${aliyun_pvtz_endpoint}" > out.json
  pvtz_id=$(jq -r .ZoneId)
  ${ALIYUN_BIN} pvtz BindZoneVpc \
    --ZoneId "${pvtz_id}" \
    --Vpcs.1.VpcId "${VPC_ID}" \
    --endpoint "${aliyun_pvtz_endpoint}"
  ${ALIYUN_BIN} pvtz AddZoneRecord \
    --ZoneId "${pvtz_id}" \
    --Type A --Rr "${CLUSTER_NAME}" \
    --Value "${bastion_private_ip}" \
    --endpoint "${aliyun_pvtz_endpoint}" > out.json
  pvtz_record_id=$(jq -r .RecordId)
  cat <<EOF >>"${SHARED_DIR}/destroy-mirror-dns.sh"
${ALIYUN_BIN} pvtz DeleteZoneRecord --RecordId "${pvtz_record_id}" --endpoint "${aliyun_pvtz_endpoint}"
${ALIYUN_BIN} pvtz BindZoneVpc --ZoneId "${pvtz_id}" --endpoint "${aliyun_pvtz_endpoint}"
${ALIYUN_BIN} pvtz DeleteZone --ZoneId "${pvtz_id}" --endpoint "${aliyun_pvtz_endpoint}"
EOF

  echo "Waiting for ${bastion_public_dns} taking effect..." && sleep 120s

  MIRROR_REGISTRY_URL="${bastion_public_dns}:5000"
  echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"
fi

echo "$(date -u --rfc-3339=seconds) - Sleeping 2 mins, make sure that the bastion host is fully started."
sleep 120

#####################################
##############Clean Up###############
#####################################
popd
rm -rf "${workdir}"
echo "$(date -u --rfc-3339=seconds) - Done creating bastion host."
