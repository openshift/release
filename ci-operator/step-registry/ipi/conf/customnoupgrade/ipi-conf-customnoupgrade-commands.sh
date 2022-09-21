#!/bin/bash
set -euo pipefail

if [ -z "$CUSTOM_FEATURE_FLAGS_ENABLED" ] && \
   [ -z "$CUSTOM_FEATURE_FLAGS_DISABLED" ]; then
    # Don't enable the feature gate if no feature flags were specified
    exit 0
fi

# Convert space-separated list to comma-separated yaml array
enabled=$(printf "[%s]" "$CUSTOM_FEATURE_FLAGS_ENABLED")
disabled=$(printf "[%s]" "$CUSTOM_FEATURE_FLAGS_DISABLED")

cat <<EOF > "${SHARED_DIR}/manifest_customnoupgrade.yaml"
---
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: "CustomNoUpgrade"
  customNoUpgrade:
    enabled: ${enabled}
    disabled: ${disabled}
EOF
