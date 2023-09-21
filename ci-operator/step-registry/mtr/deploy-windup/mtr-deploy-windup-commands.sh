#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy windup
echo "Deploying Windup"
oc apply -f - <<EOF
apiVersion: windup.jboss.org/v1
kind: Windup
metadata:
    name: mtr
    namespace: $WINDUP_NAMESPACE
    labels:
      application: mtr
spec:
    volumeCapacity: "$WINDUP_VOLUME_CAP"
EOF

# Check if Windup is deployed

# Sleep for 60 seconds to wait for the resource to be created
sleep 60

oc wait deployments -n mtr --all=true --for condition=Available --timeout=1800s