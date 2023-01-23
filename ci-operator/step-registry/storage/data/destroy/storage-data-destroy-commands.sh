#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}
export NAMESPACE="storage-data"

export MAX_STEPS=10

echo "Saving namespace $NAMESPACE in job artifacts for debugging"
oc adm inspect ns/$NAMESPACE --dest-dir="$ARTIFACT_DIR/inspect-$NAMESPACE" || :

while ! oc delete namespace $NAMESPACE --ignore-not-found=true --wait=false; do
    STEPS=$[ $STEPS - 1]
    if [ "$STEPS" == "0" ]; then
        echo "Failed to delete namespace $NAMESPACE after $MAX_STEPS attempts"
        exit 1
    fi
    sleep 10
done

echo "Deleted namespace $NAMESPACE"

while ! oc wait --for=delete ns/$NAMESPACE --timeout=1m; do
    STEPS=$[ $STEPS - 1]
    if [ "$STEPS" == "0" ]; then
        echo "Namespace $NAMESPACE still exists after $MAX_STEPS attempts"
        oc get ns $NAMESPACE -o yaml > $ARTIFACT_DIR/ns-after-deletion.yaml || :
        exit 1
    fi
    sleep 10
done

echo "Namespace $NAMESPACE is gone"
