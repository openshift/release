#!/bin/bash

###### machinesets naming test (OCP-68154) ######

function test_machinesets_naming () {
  TEST_PASSED=true

  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
  ## get first name of found machineset
  echo "Getting the name of a first available machineset to confirm that its valid"
  MACHINE_SETS_OUTPUT=""
  ## if no machinesets are found, the statement below will not assign anything to the MACHINE_SETS_OUTPUT
  MACHINE_SETS_OUTPUT=$(oc get machinesets.machine.openshift.io -A | grep "serving" | grep -v "non-serving" |  awk '{print $2}' | head -1) || true
  if [[ "$MACHINE_SETS_OUTPUT" != "" ]]; then
    # get suffix of the machineset name (e.g. for 'hs-mc-20bivna6g-wh8nq-serving-9-us-east-1b', the suffix will be 'us-east-1b')
    # it is obtained by trimming everything up to (including) 6th occurence of the '-' symbol
    echo "Confirming that the suffix of the machineset name: '$MACHINE_SETS_OUTPUT' doesn't include too many dashes - indicating double region in its name"
    SUFFIX=$(echo "$MACHINE_SETS_OUTPUT" | cut -d'-' -f7-)
    # if there are more than 4 dashes in the suffix, the name likely contains duplicated AZ in its name, e.g. 'us-east-2a-us-east-2a'
    NUMBER_OF_DASHES=$(grep -o '-' <<<"$SUFFIX" | grep -c .)
    if [ "$NUMBER_OF_DASHES" -gt 4 ]; then
      echo "Incorrect machineset name detected: $MACHINE_SETS_OUTPUT"
      TEST_PASSED=false
    fi
  else
    echo "No machinesets found."
  fi
  update_results "OCP-68154" $TEST_PASSED
}