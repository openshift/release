#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}

while ! oc get pv --no-headers --ignore-not-found -o name > ${SHARED_DIR}/initial-pvs; do
    # try until the command succeds
    sleep 5
done

# For debugging
oc get pv -o yaml > ${ARTIFACT_DIR}/pvs.yaml

echo "Saved list of PVs into ${SHARED_DIR}/initial-pvs"
