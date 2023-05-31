#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy windup
echo "Deploying Tackle"
oc apply -f - <<EOF
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: mta
spec:
  hub_bucket_volume_size: "80Gi"
  cache_data_volume_size: "20Gi"
  rwx_supported: "false"
EOF

sleep 7200
