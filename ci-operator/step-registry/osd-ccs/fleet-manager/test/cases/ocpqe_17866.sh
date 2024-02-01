#!/bin/bash

###### Create machine pools for request serving HCP components tests (OCPQE-17866) ######

function test_machineset_tains_and_labels () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Getting a name of serving machineset"
  SERVING_MACHINE_SET_NAME=""
  SERVING_MACHINE_SET_NAME=$(oc get machinesets.machine.openshift.io -A | grep -e "serving" | grep -v "non-serving" | awk '{print $2}' | head -1) || true
  if [ "$SERVING_MACHINE_SET_NAME" == "" ]; then
    echo "ERROR. Failed to get a name of a serving machineset"
    TEST_PASSED=false
  else
    echo "Getting labels of of serving machineset: $SERVING_MACHINE_SET_NAME and confirming that 'hypershift.openshift.io/request-serving-component' is set to true"
    SERVING_MACHINE_SET_REQUEST_SERVING_LABEL_VALUE=""
    SERVING_MACHINE_SET_REQUEST_SERVING_LABEL_VALUE=$(oc get machinesets.machine.openshift.io "$SERVING_MACHINE_SET_NAME" -n openshift-machine-api -o json | jq -r .spec.template.spec.metadata.labels | jq  '."hypershift.openshift.io/request-serving-component"')
    if [ "$SERVING_MACHINE_SET_REQUEST_SERVING_LABEL_VALUE" == "" ] || [ "$SERVING_MACHINE_SET_REQUEST_SERVING_LABEL_VALUE" = false ]; then
      echo "ERROR. 'hypershift.openshift.io/request-serving-component' should be present in machineset labels and set to true. Unable to get the key value pair from labels"
      TEST_PASSED=false
    fi
    echo "Getting tains of of serving machineset: $SERVING_MACHINE_SET_NAME and confirming that 'hypershift.openshift.io/request-serving-component' is set to true"
    SERVING_MACHINE_SET_REQUEST_SERVING_TAINT_VALUE=false
    SERVING_MACHINE_SET_REQUEST_SERVING_TAINT_VALUE=$(oc get machinesets.machine.openshift.io "$SERVING_MACHINE_SET_NAME" -n openshift-machine-api -o json | jq -r .spec.template.spec.taints[] | jq 'select(.key == "hypershift.openshift.io/request-serving-component")' | jq -r .value)
    if [ "$SERVING_MACHINE_SET_REQUEST_SERVING_TAINT_VALUE" = false ]; then
      echo "ERROR. 'hypershift.openshift.io/request-serving-component' should be present in machineset taints and set to true. Unable to get the key value pair from taints"
      TEST_PASSED=false
    fi
  fi

  update_results "OCPQE-17866" $TEST_PASSED
}