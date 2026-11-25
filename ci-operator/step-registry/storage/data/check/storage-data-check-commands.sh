#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}
export NAMESPACE="storage-data"
STORAGE_WORKLOAD_COUNT=${STORAGE_WORKLOAD_COUNT:-50}

export MAX_STEPS=10

echo "Saving namespace $NAMESPACE in job artifacts for debugging"
oc adm inspect ns/$NAMESPACE --dest-dir="$ARTIFACT_DIR/inspect-$NAMESPACE" || :

check_pod() {
    local NAME=$1
    local PODNAME="$NAME-0"
    local STEPS=$MAX_STEPS
    local DATAFILE="/tmp/data-$NAME"
    while ! oc exec -n $NAMESPACE $PODNAME -- sh -c "cat /mnt/test/data" > $DATAFILE ; do
        STEPS=$[ $STEPS - 1 ]
        if [ "$STEPS" == "0" ]; then
            echo "Failed to load data from pod $PODNAME after $MAX_STEPS attempts"
            exit 1
        fi
        sleep 10
    done

    DATA=$( cat $DATAFILE )
    if [ "$DATA" != "initial data" ]; then
        echo "Error: expected 'initial data', got '$DATA'"
        exit 1
    fi
    echo "Pod $PODNAME OK"
}

for I in `seq $STORAGE_WORKLOAD_COUNT`; do
    check_pod "test-$I"
done

exit 0
