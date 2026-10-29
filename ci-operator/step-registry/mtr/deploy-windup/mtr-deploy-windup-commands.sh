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
  dataSize: "$WINDUP_VOLUME_CAP"
  executorResourceLimits:
    cpuLimit: '6'
    cpuRequest: '2'
  webResourceLimits:
    cpuLimit: '6'
    cpuRequest: '2'
EOF

# Check if Windup is deployed

# Sleep for 300 seconds to wait for the resource to be created
sleep 300

oc wait deployments -n mtr --all=true --for condition=Available --timeout=1800s