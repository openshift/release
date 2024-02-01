#!/bin/bash

###### Stop installing Hypershift CRDs to service clusters tests (OCPQE-17815) ######

function test_hypershift_crds_not_installed_on_sc () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-sc.kubeconfig"
  
  echo "Confirming that hostedcluster and nodepool CRDs are not installed on service cluster"
  EXPECTED_HOSTED_CL_NODEPOOL_CRD_OUTPUT=""
  ACTUAL_HOSTED_CL_NODEPOOL_CRD_OUTPUT=$(oc get crd | grep -E 'hostedcluster|nodepool') || true

  if [ "$EXPECTED_HOSTED_CL_NODEPOOL_CRD_OUTPUT" != "$ACTUAL_HOSTED_CL_NODEPOOL_CRD_OUTPUT" ]; then
    printf "\nERROR. Expected nodepool/hostedcluster CRDs not to be installed on SC. Got:\n%s" "$ACTUAL_HOSTED_CL_NODEPOOL_CRD_OUTPUT"
    TEST_PASSED=false
  fi

  echo "Confirming that hostedcluster resource is not present on service cluster"
  EXPECTED_HOSTED_CL_OUTPUT="error: the server doesn't have a resource type \"hostedcluster\""
  ACTUAL_HOSTED_CL_OUTPUT=$(oc get hostedcluster -A 2>&1 >/dev/null) || true

  if [ "$EXPECTED_HOSTED_CL_OUTPUT" != "$ACTUAL_HOSTED_CL_OUTPUT" ]; then
    printf "\nERROR. Expected hostedcluster resource not to be found on SC. Got:\n%s" "$ACTUAL_HOSTED_CL_OUTPUT"
    TEST_PASSED=false
  fi

  echo "Confirming that nodepool resource is not present on service cluster"
  EXPECTED_NODEPOOL_OUTPUT="error: the server doesn't have a resource type \"nodepool\""
  ACTUAL_NODEPOO_OUTPUT=$(oc get nodepool -A 2>&1 >/dev/null) || true

  if [ "$EXPECTED_NODEPOOL_OUTPUT" != "$ACTUAL_NODEPOO_OUTPUT" ]; then
    printf "\nERROR. Expected nodepool resource not to be found on SC. Got:\n%s" "$ACTUAL_NODEPOO_OUTPUT"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17815" $TEST_PASSED
}