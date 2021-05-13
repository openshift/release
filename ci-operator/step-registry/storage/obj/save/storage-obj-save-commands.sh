#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}
SAVE_FILE=${SHARED_DIR}/initial-objects
STORAGE_OBJECTS=pv,csidriver,storageclass

while ! oc get $STORAGE_OBJECTS --no-headers --ignore-not-found -o name > $SAVE_FILE; do
    # try until the command succeds
    sleep 5
done

# For debugging
oc get $STORAGE_OBJECTS -o yaml > ${ARTIFACT_DIR}/objects.yaml || :

echo "Saved list of storage objects into $SAVE_FILE"
