#!/bin/bash
set -euo pipefail

cat <<EOF > ${SHARED_DIR}/manifest_cert_manager.yaml 
---
apiVersion: platform.openshift.io/v1alpha1
kind: PlatformOperator
metadata:
  name: cert-manager-po
spec:
  package:
    name: openshift-cert-manager-operator
EOF

ls -l ${SHARED_DIR}
echo "set cert-manager manifest succeed."
