#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Creating the springboot namespace..."
oc apply -f - <<EOF
    apiVersion: v1
    kind: Namespace
    metadata:
        name: "springboot"
EOF

echo "Labeling springboot namespace with XTF_MANAGED=true"
oc label namespace springboot XTF_MANAGED=true
