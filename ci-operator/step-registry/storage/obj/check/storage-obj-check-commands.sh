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

function report_flake() {
    # Create a junit file with a flake, not a failure.
    # In other words, have a test failed + passed there. CI will interpret it as a flake.
    TEST="[sig-storage] Ensure that all storage objects are deleted during the tests"
    MESSAGE="$1"
    STDOUT="$2"
    mkdir -p ${ARTIFACT_DIR}/junit/
    cat  >${ARTIFACT_DIR}/junit/junit_check.xml << EOF
<?xml version="1.0"?>
<testsuite name="$TEST" tests="2" skipped="0" failures="1" time="1">
  <testcase name="$TEST" time="0">
    <failure message="">$MESSAGE</failure>
    <system-out>$STDOUT</system-out>
  </testcase>
  <testcase name="$TEST" time="0"/>
</testsuite>
EOF
    # For build-log.txt
    echo $MESSAGE
    echo $STDOUT
}


# Fail fast if step storage-obj-save did not succeed.
if [ ! -e $SAVE_FILE ]; then
    STDOUT="Cannot find $SAVE_FILE, looks like step storage-obj-save failed. Did cluster installation succeed? $( cat $SAVE_FILE 2>&1 )"
    MSG="Error: cannot find $SAVE_FILE"
    report_flake "$MSG" "$STDOUT"
    exit 0
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
    oc get $STORAGE_OBJECTS -o yaml &> $CURRENT_OBJS.yaml || :

    if check_objects $CURRENT_OBJS ; then
        echo "All objects deleted"
        exit 0
    fi

    NOW=$( date "+%s" )
    if [ "$NOW" -gt "$FINAL_TIME" ]; then
        echo "Timeout"
        MSG="Error checking storage objects. Either some test left PVs / StorageClasses behind or connection to the API server failed. Check the diff between expected and existing objects in the test log."
        STDOUT=$(check_objects $CURRENT_OBJS || :) # We know the diff fails, override its exit code with ':'
        report_flake "$MSG" "$STDOUT"
        exit 0
    fi

    STEP=$[ $STEP + 1 ]

    sleep 10
done

exit 0
