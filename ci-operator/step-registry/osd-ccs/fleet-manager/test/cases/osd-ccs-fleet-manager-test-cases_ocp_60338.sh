#!/bin/bash

###### disable workload monitoring tests (OCP-60338) ######

function test_monitoring_disabled ()
{
  TEST_PASSED=true
  function check_monitoring_disabled () 
  {
    echo "Checking workload monitoring disabled for $1"
    # should be more than 0
    DISABLED_MONITORING_CONFIG_COUNT=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep -c "enableUserWorkload: false")
    if [ "$DISABLED_MONITORING_CONFIG_COUNT" -lt 1 ]; then
      echo "ERROR. Workload monitoring should be disabled by default"
      TEST_PASSED=false
    fi
  }

  ## check workload monitoring disabled on a service cluster

  export KUBECONFIG="${SHARED_DIR}/hs-sc.kubeconfig"
  check_monitoring_disabled "service cluster"

  ## check workload monitoring disabled on a management cluster

  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
  check_monitoring_disabled "management cluster"
  update_results "OCP-60338" $TEST_PASSED
}