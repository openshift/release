#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}

function get_final_time() {
    local DELAY=$1
    local NOW
    NOW=$( date "+%s" )
    echo $[ $NOW + $DELAY ]
}

function check_pvs() {
    local EXPECTED="$SHARED_DIR/initial-pvs"
    local GOT=$1

    # This will return proper return code
    diff -u $EXPECTED $GOT
}

STEP=1
# Finish in 300 seconds
FINAL_TIME=$( get_final_time 300 )

while true; do
    echo
    echo "$(date) Attempt $STEP"

    CURRENT_PVS="$ARTIFACT_DIR/pvs-$STEP"
    oc get pv --no-headers --ignore-not-found -o name &> $CURRENT_PVS || :

    # for debugging
    oc get pv -o yaml > $CURRENT_PVS.yaml || :

    if check_pvs $CURRENT_PVS ; then
        echo "All PVs deleted"
        exit 0
    fi

    NOW=$( date "+%s" )
    if [ "$NOW" -gt "$FINAL_TIME" ]; then
        echo "ERROR: Timed out waiting for PVs to get deleted."
        echo "ERROR: It seems that some test left some PVs behind."
        echo "ERROR: Check the diff between expected and existing PVs above."
        exit 1
    fi

    STEP=$[ $STEP + 1 ]

    sleep 10
done
