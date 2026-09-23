#!/bin/bash
set -euo pipefail

cat <<EOF > ${SHARED_DIR}/manifest_service_mesh.yaml 
---
apiVersion: platform.openshift.io/v1alpha1
kind: PlatformOperator
metadata:
  name: service-mesh-po
spec:
  package:
    name: servicemeshoperator
EOF

ls -l ${SHARED_DIR}
echo "set service mesh operator manifest succeed."
