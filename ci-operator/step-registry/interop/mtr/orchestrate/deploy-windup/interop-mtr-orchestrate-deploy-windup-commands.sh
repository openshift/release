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
    namespace: mtr
    labels:
      application: mtr
spec:
    volumeCapacity: "5Gi"
EOF

# Wait 5 minutes for Windup to fully deploy
echo "Waiting 5 minutes for Windup to finish deploying"
sleep 300
echo "Windup operator installed and Windup deployed."