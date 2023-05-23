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

# Sleep for 5 seconds to wait for the resource to be created
sleep 5

RETRIES=60
for try in $(seq "$RETRIES"); do
    READY=$(oc get windup -n mtr -o=jsonpath='{.items[0].status.conditions[1].status}')
    if [[ $READY == "True" ]]; then
        echo "Windup is ready."
        break
    else
        if [ $try == $RETRIES ]; then
            echo "Error deploying Windup, exiting now"
            exit 1
        fi
        echo "Try ${try}/${RETRIES}: Windup deployment is not ready. Checking again in 30 seconds"
        sleep 30
    fi
done