#!/bin/bash
set -euo pipefail

cat <<EOF > ${SHARED_DIR}/manifest_feature_gate.yaml
---
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  annotations:
    include.release.openshift.io/self-managed-high-availability: "true"
    include.release.openshift.io/single-node-developer: "true"
    release.openshift.io/create-only: "true"
  name: cluster
spec:
  customNoUpgrade:
    enabled:
    - ExternalCloudProvider
    - CSIMigrationAWS
    - CSIMigrationOpenStack
    - CSIMigrationAzureDisk
    - CSIDriverAzureDisk
  featureSet: CustomNoUpgrade
EOF
