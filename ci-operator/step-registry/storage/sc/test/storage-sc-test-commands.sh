#!/bin/bash

set -o xtrace
set -o errexit
set -o nounset
set -o pipefail

DEFAULT_PROVISIONER_NAME=`oc get sc -o=jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].provisioner}'`
DEFAULT_SC_NAME=`oc get sc -o=jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'`
PROVISIONER_NAME=${PROVISIONER_NAME:-${DEFAULT_PROVISIONER_NAME}}
SC_NAME=${SC_NAME:-${DEFAULT_SC_NAME}}
SLEEP_INTERVAL=${SLEEP_INTERVAL:-10}
MAX_STEPS=${MAX_STEPS:-10}
DEBUG=${DEBUG:-0}

# disable tracing unless DEBUG is set
[ $DEBUG -ne 0 ] || set +o xtrace

get_sc_state() {
    oc get clustercsidriver $PROVISIONER_NAME -o=jsonpath='{.spec.storageClassState}'
    if [ $? -ne 0 ]; then
        echo "Failed to get ClusterCSIDriver $PROVISIONER_NAME"
	exit 1
    fi
}

set_sc_state() {
    local STATE=$1
    local STEPS=$MAX_STEPS
    echo "Setting StorageClassState to $STATE on $PROVISIONER_NAME"
    while ! oc patch clustercsidriver $PROVISIONER_NAME --type=merge -p "{\"spec\":{\"storageClassState\":\"${STATE}\"}}"; do
        STEPS=$[ $STEPS - 1 ]
        if [ $STEPS -eq 0 ]; then
            echo "Failed to patch ClusterCSIDriver $PROVISIONER_NAME after $MAX_STEPS attempts"
            exit 1
        fi
        sleep $SLEEP_INTERVAL
    done
}

get_allow_expansion() {
    oc get sc $SC_NAME -o=jsonpath='{.allowVolumeExpansion}'
    if [ $? -ne 0 ]; then
        echo "Failed to get StorageClass $SC_NAME"
	exit 1
    fi
}

set_allow_expansion() {
    local VALUE=$1
    local STEPS=$MAX_STEPS
    echo "Setting AllowVolumeExpansion to $VALUE on $SC_NAME"
    while ! oc patch sc $SC_NAME -p "{\"allowVolumeExpansion\":${VALUE}}"; do
        STEPS=$[ $STEPS - 1 ]
        if [ $STEPS -eq 0 ]; then
            echo "Failed to patch StorageClass $SC_NAME after $MAX_STEPS attempts"
            exit 1
        fi
        sleep $SLEEP_INTERVAL
    done
}

verify_allow_expansion() {
    local EXPECTED_VALUE=$1
    local STEPS=$MAX_STEPS
    local OUTPUT=""
    echo "Expecting AllowVolumeExpansion to be $EXPECTED_VALUE after $SLEEP_INTERVAL seconds"
    while [ "$OUTPUT" != "$EXPECTED_VALUE" ]; do
        STEPS=$[ $STEPS - 1 ]
        if [ $STEPS -eq 0 ]; then
            echo "AllowVolumeExpansion does not match $EXPECTED_VALUE after $MAX_STEPS attempts"
            exit 1
        fi
        sleep $SLEEP_INTERVAL
	OUTPUT=`get_allow_expansion`
    done
    echo "AllowVolumeExpansion on $SC_NAME matches expected value $EXPECTED_VALUE"
}

verify_sc_exists() {
    local EXPECTED_RETURN=$1
    local STEPS=$MAX_STEPS
    local RC=-1
    echo "Checking if StorageClass $SC_NAME exists, expected return value: $EXPECTED_RETURN"
    while [ $RC -ne $EXPECTED_RETURN ]; do
        STEPS=$[ $STEPS - 1 ]
        if [ $STEPS -eq 0 ]; then
            echo "'oc get sc $SC_NAME' does not match expected return value after $MAX_STEPS attempts"
            exit 1
        fi
        sleep $SLEEP_INTERVAL
        set +o errexit
	oc get sc $SC_NAME &> /dev/null
	RC=$?
        set -o errexit
    done
    echo "Got expected return value $EXPECTED_RETURN"
}

test_setup() {
    local STATE="Managed"
    echo "Setup: initialize StorageClassState to $STATE on $PROVISIONER_NAME"
    set_sc_state $STATE
    verify_sc_exists 0 # SC should exist
}

test_unmanaged_state() {
    local STATE="Unmanaged"
    local ALLOW_EXPANSION="false"
    echo "Testing $STATE StorageClassState"
    set_sc_state $STATE
    set_allow_expansion $ALLOW_EXPANSION
    verify_allow_expansion $ALLOW_EXPANSION # change should persist
    echo "$STATE test PASSED"
}

test_removed_state() {
    local STATE="Removed"
    echo "Testing $STATE StorageClassState"
    set_sc_state $STATE
    verify_sc_exists 1 # SC should NOT exist
    echo "$STATE test PASSED"
}

test_managed_state() {
    local STATE="Managed"
    local ALLOW_EXPANSION="false"
    echo "Testing $STATE StorageClassState"
    set_sc_state $STATE
    verify_sc_exists 0 # SC should exist
    set_allow_expansion $ALLOW_EXPANSION
    verify_allow_expansion "true" # change should be reverted
    echo "$STATE test PASSED"
}

test_setup
test_unmanaged_state
test_removed_state
test_managed_state
echo "All tests PASSED"

exit 0
