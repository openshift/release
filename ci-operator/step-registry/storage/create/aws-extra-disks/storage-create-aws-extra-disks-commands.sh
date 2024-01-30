#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# Create an AWS EBS volume, volInfraTag will help delete volume when deleting cluster 
function create_ebs_volume(){
  if [ $# -ne 6 ] ;then
    echo "Usage: create_ebs_volume <volName> <availabilityZone> <volSize> <volType> <volInfraTag> <region>" && return 1
  fi 

  volName=$1
  availabilityZone=$2
  volSize=$3
  volType=$4
  volInfraTag=$5
  region=$6

  # Adding "kubernetes.io/cluster/${volInfraTag}: owned" tag to make sure volume will be deleted when destroy cluster by installer
  tags="ResourceType=volume,Tags=[{Key=kubernetes.io/cluster/${volInfraTag},Value=owned},{Key=Name,Value=${volName}}]" 
  cmd="aws ec2 create-volume --region ${region} --availability-zone ${availabilityZone} --size ${volSize} --volume-type ${volType} --tag-specification '${tags}' --query VolumeId --output text"
  echo "Command used: ${cmd}"
  volumeId=$(eval "${cmd}")
  if [ "X${volumeId}" != "X" ];then
    echo "Creating volume ${volumeId} succeed!"
  else
    echo "Creating volume failed, exit!" 
    return 1
  fi
}

# Wait EBS volume status as expected
function wait_ebs_volume_status(){
  if [ $# -ne 2 ] ;then
    echo "Usage: wait_ebs_volume_status <volumeId> <status>" && return 1
  fi
 
  volumeId=$1
  status=$2
  iter=6
  period=10
  echo "Checking and waiting status EBS volume ${volumeId} to be ${status} ..."   
  result=""
  while [[ "${result}" != "${status}" && $iter -gt 0 ]]; do
    result=$(aws ec2 describe-volumes --region "${region}" --volume-ids "${volumeId}" --query "Volumes[0].State" --output text)
    (( iter -- ))
    sleep $period
  done
  if [ "${result}" == "${status}" ]; then
    echo "EBS volume: ${volumeId} is ${status}, expected!"  
  else
    echo "EBS volume: ${volumeId} is ${result} while expected status is ${status}" && return 1
  fi
}

# Get an unused device name from node
function get_device_name(){
  if [ $# -ne 1 ] ;then
    echo "Usage: get_device_name <instanceId>" && return 1
  fi
  instanceId=$1
  cmd="aws ec2 describe-instances --region ${region} --instance-ids ${instanceId} --query 'Reservations[0].Instances[0].BlockDeviceMappings[].DeviceName' --output text"
  echo "Command used: ${cmd}"
  deviceList=$(eval "${cmd}")
  fullDeviceList="sdp sdo sdn sdm sdl sdk sdj sdi sdh sdg sdf"
  deviceName=""
  for device in ${fullDeviceList};do
    result=$(echo "${deviceList}" | grep "${device}")
    if [ "X${result}" == "X" ];then
      deviceName="/dev/$device"
      echo "Will use device name ${deviceName} to attach"
      break
    fi
  done
  if [ "X${deviceName}" == "X" ];then
    echo "There is not available device name to attach, exit!" && return 1
  fi
}

# Attach EBS volume to instance
function attach_ebs_volume(){
  if [ $# -ne 3 ] ;then
    echo "Usage: attach_ebs_volume <deviceName> <instanceId> <volumeId>" && return 1
  fi
  deviceName=$1
  instanceId=$2
  volumeId=$3
  cmd="aws ec2 attach-volume --region ${region} --device ${deviceName} --instance-id ${instanceId} --volume-id ${volumeId}"
  echo "Command used: ${cmd}"
  if ${cmd};then
    echo "Attaching EBS volume ${volumeId} to instance ${instanceId}"
  else
    echo "Attaching EBS volume ${volumeId} to instance ${instanceId} failed, exit!" && return 1
  fi
}

infrastructureName=$(oc get infrastructures cluster -o json | jq -r .status.infrastructureName)

if [ "${NODE_ROLE}" == "all" ];then
  nodes=$(oc get nodes --no-headers | awk '{print $1}')
else
  nodes=$(oc get nodes --no-headers -l "node-role.kubernetes.io/${NODE_ROLE}" | awk '{print $1}')
fi

for nodename in ${nodes};do
  instanceId=$(oc get node "${nodename}" -o json | jq -r .spec.providerID | awk -F "/" '{print $NF}')
  region=$(oc get node "${nodename}" -o json | jq -r '.metadata.labels."topology.kubernetes.io/region"')
  availabilityZone=$(oc get node "${nodename}" -o json | jq -r '.metadata.labels."topology.kubernetes.io/zone"')
  volName=${nodename}-ci-extra-$(date "+%Y%m%d%M%S")
  
  for i in $(seq "${EXTRA_DISKS_COUNT}"); do
    create_ebs_volume "${volName}"-"${i}" "${availabilityZone}" "${EXTRA_DISKS_SIZE}" "${EXTRA_DISKS_TYPE}" "${infrastructureName}" "${region}" || exit 1
    wait_ebs_volume_status "${volumeId}" "available"  || exit 1
    get_device_name "${instanceId}"  || exit 1
    attach_ebs_volume "${deviceName}" "${instanceId}" "${volumeId}" || exit 1
    wait_ebs_volume_status "${volumeId}" "in-use"  || exit 1
    echo "Done: Attached ${volumeId} to ${instanceId} successfully!"
  done

done
