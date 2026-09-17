#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Creating FeatureGate manifest to disable IngressControllerDynamicConfigurationManager..."

cat > "${SHARED_DIR}/manifest_featuregate.yaml" << 'EOF'
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: CustomNoUpgrade
  customNoUpgrade:
    disabled:
    - IngressControllerDynamicConfigurationManager
EOF

echo "FeatureGate manifest created in ${SHARED_DIR}/manifest_featuregate.yaml"
cat "${SHARED_DIR}/manifest_featuregate.yaml"
