#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

GCP_BASE_DOMAIN="origin-ci-int-gce.dev.openshift.com"
GCP_PROJECT="openshift-gce-devel-ci"
GCP_REGION="us-east1"

cat >> "${CONFIG}" << EOF
baseDomain: ${GCP_BASE_DOMAIN}
platform:
  gcp:
    projectID: ${GCP_PROJECT}
    region: ${GCP_REGION}
compute:
- name: worker
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

