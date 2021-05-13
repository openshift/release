#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}
SAVE_FILE=${SHARED_DIR}/initial-objects
STORAGE_OBJECTS=pv,csidriver,storageclass

function get_final_time() {
    local DELAY=$1
    local NOW
    NOW=$( date "+%s" )
    echo $[ $NOW + $DELAY ]
}

function check_objects() {
    local EXPECTED=$SAVE_FILE
    local GOT=$1

    # This will return proper return code
    diff -u $EXPECTED $GOT
}


# Fail fast if step storage-obj-save did not succeed.
if [ ! -e $SAVE_FILE ]; then
    echo "Cannot find $SAVE_FILE, looks like step storage-obj-save failed."
    exit 1
fi

STEP=1
# Finish in 300 seconds
FINAL_TIME=$( get_final_time 300 )

while true; do
    echo
    echo "$(date) Attempt $STEP"

    CURRENT_OBJS="$ARTIFACT_DIR/objects-$STEP"
    oc get $STORAGE_OBJECTS --no-headers --ignore-not-found -o name &> $CURRENT_OBJS || :

    # for debugging
    oc get $STORAGE_OBJECTS -o yaml > $CURRENT_OBJS.yaml || :

    if check_objects $CURRENT_OBJS ; then
        echo "All objects deleted"
        exit 0
    fi

    NOW=$( date "+%s" )
    if [ "$NOW" -gt "$FINAL_TIME" ]; then
        echo "ERROR: Timed out waiting for storage objects to get deleted."
        echo "ERROR: It seems that some test left some of them behind or API server failed."
        echo "ERROR: Check the diff between expected and existing objects above."
        exit 1
    fi

    STEP=$[ $STEP + 1 ]

    sleep 10
done
