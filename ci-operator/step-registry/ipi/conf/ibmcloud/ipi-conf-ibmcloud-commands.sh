#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ -z "${SIZE_VARIANT}" ]]; then
    SIZE_VARIANT=default
fi

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
    workers=0
elif [ -n "${WORKERS}" ]; then
    workers="${WORKERS}"
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
REGION="${LEASED_RESOURCE}"
echo "ibmcloud region: ${REGION}"
ZONES_COUNT=${ZONES_COUNT:-1}
R_ZONES=("${REGION}-1" "${REGION}-2" "${REGION}-3")
ZONES="${R_ZONES[*]:0:${ZONES_COUNT}}"
ZONES_STR="[ ${ZONES// /, } ]"
echo "IBM Cloud region: ${REGION} (zones: ${ZONES_STR})"

# Populate install-config with IBM Cloud Platform specifics
cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
credentialsMode: Manual
platform:
  ibmcloud:
    region: ${REGION}
EOF

if [[ "${RESOURCE_GROUP}" ]]; then
cat >> "${CONFIG}" << EOF
    resourceGroupName: ${RESOURCE_GROUP}
EOF
fi

cat >> "${CONFIG}" << EOF
controlPlane:
  name: master
  platform:
    ibmcloud:
      type: ${master_type}
      zones: ${ZONES_STR}
  replicas: ${CONTROL_PLANE_REPLICAS}
compute:
- name: worker
  platform:
    ibmcloud:
      type: ${COMPUTE_NODE_TYPE}
      zones: ${ZONES_STR}
  replicas: ${workers}
EOF

if [ ${RT_ENABLED} = "true" ]; then
	cat > "${SHARED_DIR}/manifest_mc-kernel-rt.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: realtime-worker
spec:
  kernelType: realtime
EOF
fi