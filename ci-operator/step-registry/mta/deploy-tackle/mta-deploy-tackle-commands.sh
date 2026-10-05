#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

TACKLE_NAMESPACE="mta"
HUB_BUCKET_VOLUME_SIZE="80Gi"
CACHE_DATA_VOLUME_SIZE="20Gi"
RWX_SUPPORTED="false"

# Deploy windup
echo "Deploying Tackle"
oc apply -f - <<EOF
kind: Tackle
apiVersion: tackle.konveyor.io/v1alpha1
metadata:
  name: tackle
  namespace: $TACKLE_NAMESPACE
spec:
  hub_bucket_volume_size: "$HUB_BUCKET_VOLUME_SIZE"
  cache_data_volume_size: "$CACHE_DATA_VOLUME_SIZE"
  rwx_supported: "$RWX_SUPPORTED"
EOF

# Check if Tackle is deployed

# Sleep for 5 seconds to wait for the resource to be created
sleep 5

RETRIES=60
for try in $(seq "$RETRIES"); do
    # Get list of running pods using the mta app and the defined namespace
    pods=$(oc get pods --selector 'app=mta' --namespace $TACKLE_NAMESPACE)

    # Check if any of the pods match the name "mta-ui-***"
    for pod in $pods; do
        if [[ $pod =~ mta-ui- ]]; then
            if [[ $(oc get pods -n $TACKLE_NAMESPACE -o jsonpath="{.items[?(@.metadata.name=='${pod}')].status.phase}") == "Running" ]]; then
                echo "Tackle is ready."
                break 2
            else
                echo "Try ${try}/${RETRIES}: Tackle deployment is not ready. Checking again in 30 seconds"
                sleep 30
            fi
        fi
    done
    echo "Try ${try}/${RETRIES}: Tackle deployment is not ready. Checking again in 30 seconds"
    sleep 30
done