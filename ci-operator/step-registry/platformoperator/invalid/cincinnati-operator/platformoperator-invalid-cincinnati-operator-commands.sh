#!/bin/bash
set -euo pipefail

cat <<EOF > ${SHARED_DIR}/manifest_cincinnati_operator.yaml 
---
apiVersion: platform.openshift.io/v1alpha1
kind: PlatformOperator
metadata:
  name: cincinnati-po
spec:
  package:
    name: cincinnati-operator
EOF

