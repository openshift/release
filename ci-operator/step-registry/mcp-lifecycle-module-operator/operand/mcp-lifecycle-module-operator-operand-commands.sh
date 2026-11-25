#!/bin/bash
set -euo pipefail

oc apply -f - <<EOF
apiVersion: components.platform.opendatahub.io/v1alpha1
kind: MCPLifecycleOperator
metadata:
  name: default
spec:
  managementState: Managed
EOF

oc wait --for=condition=Ready mcplifecycleoperator/default --timeout=10m
