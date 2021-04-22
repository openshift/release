#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GCP_REGION="${LEASED_RESOURCE}"

masters="${CONTROL_PLANE_REPLICAS}"

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi
master_type=null
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type=n1-standard-32
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type=n1-standard-16
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type=n1-standard-8
fi

cat >> "${CONFIG}" << EOF
baseDomain: ${GCP_BASE_DOMAIN}
platform:
  gcp:
    projectID: ${GCP_PROJECT}
    region: ${GCP_REGION}
controlPlane:
  name: master
  platform:
    gcp:
      type: ${master_type}
  replicas: ${masters}
compute:
- name: worker
  replicas: ${workers}
  platform:
    gcp:
      type: ${COMPUTE_NODE_TYPE}
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

