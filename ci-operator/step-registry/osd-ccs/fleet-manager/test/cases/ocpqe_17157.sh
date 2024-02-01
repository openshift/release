#!/bin/bash

###### MC srep-worker-healthcheck MHC check (OCPQE-17157) ######

function test_machine_health_check_config () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Checking MC MHC match expressions operator"
  EXPECTED_MHC_MATCH_EXPRESSIONS_OPERATOR="NotIn"
  ACTUAL_MHC_MATCH_EXPRESSIONS_OPERATOR=""
  ACTUAL_MHC_MATCH_EXPRESSIONS_OPERATOR=$(oc get machinehealthchecks.machine.openshift.io srep-worker-healthcheck -n openshift-machine-api -o json | jq -r .spec.selector.matchExpressions[] | jq 'select(.key == ("machine.openshift.io/cluster-api-machine-role"))' | jq -r .operator) || true

  if [[ "$EXPECTED_MHC_MATCH_EXPRESSIONS_OPERATOR" != "$ACTUAL_MHC_MATCH_EXPRESSIONS_OPERATOR" ]]; then
    echo "ERROR: Expected the matching expressions operator to be '$EXPECTED_MHC_MATCH_EXPRESSIONS_OPERATOR'. Found: '$ACTUAL_MHC_MATCH_EXPRESSIONS_OPERATOR'"
    TEST_PASSED=false
  fi

  echo "Checking that MHC health check excludes 'master' and 'infra' machines"
  EXPECTED_EXCLUDED_IN_MHC=1
  MASTER_MACHINES_EXCLUDED=0
  INFRA_MACHINES_EXCLUDED=0
  WORKER_MACHINES_EXCLUDED=-1
  MASTER_MACHINES_EXCLUDED=$(oc get machinehealthchecks.machine.openshift.io srep-worker-healthcheck -n openshift-machine-api -o json | jq -r .spec.selector.matchExpressions[] | jq 'select(.key == ("machine.openshift.io/cluster-api-machine-role"))' | jq -r .values | grep -c master) || true
  INFRA_MACHINES_EXCLUDED=$(oc get machinehealthchecks.machine.openshift.io srep-worker-healthcheck -n openshift-machine-api -o json | jq -r .spec.selector.matchExpressions[] | jq 'select(.key == ("machine.openshift.io/cluster-api-machine-role"))' | jq -r .values | grep -c infra) || true
  WORKER_MACHINES_EXCLUDED=$(oc get machinehealthchecks.machine.openshift.io srep-worker-healthcheck -n openshift-machine-api -o json | jq -r .spec.selector.matchExpressions[] | jq 'select(.key == ("machine.openshift.io/cluster-api-machine-role"))' | jq -r .values | grep -c worker) || true

  # 1 expecred - master machines should be included in the 'NotIn' mhc operator check
  if [ "$MASTER_MACHINES_EXCLUDED" -ne "$EXPECTED_EXCLUDED_IN_MHC" ]; then
    echo "ERROR: Expected master machines to be included in the 'NotIn' match expression for the MC MHC"
    TEST_PASSED=false
  fi

  # 1 expecred - infra machines should be included in the 'NotIn' mhc operator check
  if [ "$INFRA_MACHINES_EXCLUDED" -ne "$EXPECTED_EXCLUDED_IN_MHC" ]; then
    echo "ERROR: Expected infra machines to be included in the 'NotIn' match expression for the MC MHC"
    TEST_PASSED=false
  fi

  echo "Checking that MHC health check includes 'worker' machines"

  # 0 expecred - worker machines should not be included in the 'NotIn' mhc operator check
  if [ "$WORKER_MACHINES_EXCLUDED" -eq "$EXPECTED_EXCLUDED_IN_MHC" ]; then
    echo "ERROR: Expected worker machines not to be included in the 'NotIn' match expression for the MC MHC"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17157" $TEST_PASSED
}