#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

cat << EOF| oc replace -f -
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: CustomNoUpgrade 
  customNoUpgrade:
    enabled:
    - ${FEATURE}
EOF

oc adm wait-for-stable-cluster --timeout=2h