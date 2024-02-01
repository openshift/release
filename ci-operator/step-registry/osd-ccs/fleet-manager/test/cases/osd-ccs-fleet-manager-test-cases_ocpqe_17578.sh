#!/bin/bash

###### test fix for 'Pods can be created on MC request serving nodes before taints are applied' (OCPQE-17578) ######

function test_compliance_monkey_descheduler () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Checking that compliance-monkey deployment is present and contains descheduler container"
  EXPECTED_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT=1
  ACTUAL_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT=0
  ACTUAL_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT=$(oc get deployment compliance-monkey -n openshift-compliance-monkey -o json | jq -r .spec.template.spec.containers[].args | grep -c descheduler) || true

  if [ "$EXPECTED_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT" -ne "$ACTUAL_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT" ]; then
    echo "ERROR: Expected compliance-monkey deployment to be present and containing descheduler container"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17578" $TEST_PASSED
}