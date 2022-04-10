#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

: '
Temporarily commenting out this section (lines 11 - 50 below) until profiles are supported in powervs environment
if [[ -z "${SIZE_VARIANT}" ]]; then
    SIZE_VARIANT=default
fi

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
    workers=0
fi

master_type=null
case "${SIZE_VARIANT}" in
    compact)
        master_type=bx2-8x32
        ;;
    default)
        master_type=bx2-4x16
        ;;
    large)
        master_type=bx2-16x64
        ;;
    xlarge)
        master_type=bx2-32x128
        ;;
    *)
        echo "Invalid 'SIZE_VARIANT', ${SIZE_VARIANT}."
	exit 1
	;;
esac

# Select zone(s) based on REGION and ZONE_COUNT
# TODO(cjschaef): Set the REGION from LEASED_RESOURCE, if possible
#REGION="${LEASED_RESOURCE}"
REGION=lon
ZONES_COUNT=${ZONES_COUNT:-1}
R_ZONES=("${REGION}-1" "${REGION}-2" "${REGION}-3")
ZONES="${R_ZONES[*]:0:${ZONES_COUNT}}"
ZONES_STR="[ ${ZONES// /, } ]"
echo "Powervs region: ${REGION} (zones: ${ZONES_STR})"

Temporarily commented out the above lines as we are not using these properties for now. Will visit in later and set the profiles.
  '

# Populate install-config with Powervs Platform specifics
# Note: we will visit this creation of install-config.yaml file section once the profile support is added to the powervs environment
cat > "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ocp-ppc64le.com
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: ppc64le
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 2
controlPlane:
  architecture: ppc64le
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: powervs-ci
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  powervs:
    APIKey: ${POWERVS_API_KEY}
    powervsResourceGroup: "powervs-ipi-resource-group"
    region: lon
    serviceInstance: "${POWERVS_SERVICE_INSTANCE}"
    userID: ${POWERVS_USER_ID}
    zone: lon06
    vpcRegion: eu-gb
    vpc: "powervs-ci-ipi"
    subnets:
    - subnet2
    pvsNetworkName: pvs-ci-ipi-net
publish: External
pullSecret: >
  $(<"${CLUSTER_PROFILE_DIR}/pull-secret")
sshKey: |
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF
