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

# Wait 5 minutes for Windup to fully deploy
echo "Waiting 5 minutes for Windup to finish deploying"
sleep 300
echo "Windup operator installed and Windup deployed."