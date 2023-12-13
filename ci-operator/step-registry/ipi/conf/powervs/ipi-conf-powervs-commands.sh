#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "ARCH=${ARCH}"
echo "BRANCH=${BRANCH}"

CONFIG="${SHARED_DIR}/install-config.yaml"

# Temporarily commenting out this section (lines 11 - 50 below) until profiles are supported in powervs environment
# if [[ -z "${SIZE_VARIANT}" ]]; then
#    SIZE_VARIANT=default
# fi
#
# workers=3
# if [[ "${SIZE_VARIANT}" == "compact" ]]; then
#    workers=0
# fi
#
# master_type=null
# case "${SIZE_VARIANT}" in
#    compact)
#        master_type=bx2-8x32
#        ;;
#    default)
#        master_type=bx2-4x16
#        ;;
#    large)
#        master_type=bx2-16x64
#        ;;
#    xlarge)
#        master_type=bx2-32x128
#        ;;
#    *)
#        echo "Invalid 'SIZE_VARIANT', ${SIZE_VARIANT}."
#	exit 1
#	;;
# esac

# Select zone(s) based on REGION and ZONE_COUNT
# TODO(cjschaef): Set the REGION from LEASED_RESOURCE, if possible
#REGION="${LEASED_RESOURCE}"
#REGION=lon
#ZONES_COUNT=${ZONES_COUNT:-1}
#R_ZONES=("${REGION}-1" "${REGION}-2" "${REGION}-3")
#ZONES="${R_ZONES[*]:0:${ZONES_COUNT}}"
#ZONES_STR="[ ${ZONES// /, } ]"
#echo "Powervs region: ${REGION} (zones: ${ZONES_STR})"

#Temporarily commented out the above lines as we are not using these properties for now. Will visit in later and set the profiles.

# Populate install-config with Powervs Platform specifics
# Note: we will visit this creation of install-config.yaml file section once the profile support is added to the powervs environment
POWERVS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.powervscred"
CLUSTER_NAME="rdr-multiarch-${LEASED_RESOURCE}"
POWERVS_RESOURCE_GROUP=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_RESOURCE_GROUP")
POWERVS_USER_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_USER_ID")

if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

PLATFORM_ARGS_COMPUTE=( )
PLATFORM_ARGS_WORKER=( )
POWERVS_ZONE=${LEASED_RESOURCE}
case "${LEASED_RESOURCE}" in
   "dal10")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_DAL10")
      POWERVS_REGION=dal
      VPCREGION=us-south
   ;;
   "lon04")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_LON04")
      POWERVS_REGION=lon
      VPCREGION=eu-gb
   ;;
   "mon01")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_MON01")
      POWERVS_REGION=mon
      VPCREGION=ca-tor
   ;;
   "osa21")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_OSA21")
      POWERVS_REGION=osa
      VPCREGION=jp-osa
      PLATFORM_ARGS_COMPUTE+=( "sysType" "e980" )
      PLATFORM_ARGS_WORKER+=( "sysType" "e980" )
   ;;
   "sao01")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_SAO01")
      POWERVS_REGION=sao
      VPCREGION=br-sao
   ;;
   "syd04")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_SYD04")
      POWERVS_REGION=syd
      VPCREGION=au-syd
   ;;
   "syd05")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_SYD05")
      POWERVS_REGION=syd
      VPCREGION=au-syd
   ;;
   "tor01")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_TOR01")
      POWERVS_REGION=tor
      VPCREGION=ca-tor
   ;;
   "tok04")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_TOK04")
      POWERVS_REGION=tok
      VPCREGION=jp-tok
   ;;
   "wdc06")
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID_WDC06")
      POWERVS_REGION=wdc
      VPCREGION=us-east
   ;;
   *)
      # Default Region & Zone
      POWERVS_SERVICE_INSTANCE_ID=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_SERVICE_INSTANCE_ID")
      POWERVS_REGION=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/POWERVS_REGION")
      VPCREGION=$(cat "/var/run/powervs-ipi-cicd-secrets/powervs-creds/VPCREGION")
   ;;
esac

echo "CONTROL_PLANE_REPLICAS=${CONTROL_PLANE_REPLICAS}"
echo "WORKER_REPLICAS=${WORKER_REPLICAS}"
# Are we performing a Single Node OpenShift cluster deploy?
if [[ "${CONTROL_PLANE_REPLICAS}" == "1" && "${WORKER_REPLICAS}" == "0" ]]; then
  PLATFORM_ARGS_COMPUTE+=( "procType" "Dedicated" )
  PLATFORM_ARGS_COMPUTE+=( "processors" 6 )
fi

FILE=$(mktemp)

trap '/bin/rm ${FILE}' EXIT

cat << '___EOF___' > ${FILE}
import sys
import yaml

nargs = len(sys.argv)
if ((nargs % 2) == 0):
	raise ValueError("Error: Usage: program key value [ key value ]*")

# Remove the first argument
nargs -= 1

cfg = {}
cfg["platform"] = {}
cfg["platform"]["powervs"] = {}

# Loop through key/value pairs
index = 1
while index < nargs:
	key = sys.argv[index]
	value = sys.argv[index+1]
	try:
		value = int(value)
	except ValueError:
		pass
	cfg["platform"]["powervs"][key] = value
	index += 2

# Create YAML output
output = yaml.safe_dump(cfg, default_flow_style=False)

# Insert two spaces before every line in order to match outside spacing
print('  '.join(('\n'+output).splitlines(True))[1:].rstrip())
___EOF___

pip3 install pyyaml --user
echo "PLATFORM_ARGS_COMPUTE=${PLATFORM_ARGS_COMPUTE[*]}"
echo "PLATFORM_ARGS_WORKER=${PLATFORM_ARGS_WORKER[*]}"
CONFIG_PLATFORM_COMPUTE=$(python3 ${FILE} "${PLATFORM_ARGS_COMPUTE[@]}")
CONFIG_PLATFORM_WORKER=$(python3 ${FILE} "${PLATFORM_ARGS_WORKER[@]}")
echo "CONFIG_PLATFORM_COMPUTE=${CONFIG_PLATFORM_COMPUTE}"
echo "CONFIG_PLATFORM_WORKER=${CONFIG_PLATFORM_WORKER}"

cat > "${SHARED_DIR}/powervs-conf.yaml" << EOF
CLUSTER_NAME: ${CLUSTER_NAME}
POWERVS_SERVICE_INSTANCE_ID: ${POWERVS_SERVICE_INSTANCE_ID}
POWERVS_REGION: ${POWERVS_REGION}
POWERVS_ZONE: ${POWERVS_ZONE}
VPCREGION: ${VPCREGION}
EOF

export POWERVS_SHARED_CREDENTIALS_FILE

if echo ${BRANCH} | awk -F. '{ if ($1 == 4 && $2 <= 14) { exit 0 } else { exit 1 } }'; then
  # In 4.14 releases or earlier, the parameter is named serviceInstanceID and is a required
  # parameter.
  SERVICE_INSTANCE="serviceInstanceID"
else
  # In 4.15 releases or later, the parameter is named serviceInstanceGUID and is an optional
  # parameter.
  SERVICE_INSTANCE="serviceInstanceGUID"
fi
echo "SERVICE_INSTANCE=${SERVICE_INSTANCE}"

cat > "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: ppc64le
  hyperthreading: Enabled
  name: worker
${CONFIG_PLATFORM_WORKER}
  replicas: ${WORKER_REPLICAS}
controlPlane:
  architecture: ppc64le
  hyperthreading: Enabled
  name: master
${CONFIG_PLATFORM_COMPUTE}
  replicas: ${CONTROL_PLANE_REPLICAS}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 192.168.124.0/24
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  powervs:
    powervsResourceGroup: "${POWERVS_RESOURCE_GROUP}"
    region: ${POWERVS_REGION}
    ${SERVICE_INSTANCE}: "${POWERVS_SERVICE_INSTANCE_ID}"
    userID: ${POWERVS_USER_ID}
    zone: ${POWERVS_ZONE}
    vpcRegion: ${VPCREGION}
publish: External
pullSecret: >
  $(<"${CLUSTER_PROFILE_DIR}/pull-secret")
sshKey: |
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF
