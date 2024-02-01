#!/bin/bash

###### Ensure only ready management clusters are considered in ACM's placement decision test (OCPQE-17818) ######

function test_ready_mc_acm_placement_decision () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-sc.kubeconfig"

  echo "Confirming that api.openshift.com/osdfm-cluster-status is ready in the ManagedCluster resource on SC"
  EXPECTED_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT=1
  ACTUAL_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT=0
  ACTUAL_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT=$(oc get ManagedCluster -o json | grep "\"api.openshift.com/osdfm-cluster-status"\" | grep -c "ready")
  if [ "$EXPECTED_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT" != "$ACTUAL_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT" ]; then
    printf "\nERROR. Expected count of 'api.openshift.com/osdfm-cluster-status: ready' in ManagedCluster resource SC to be 1. Got:\n%d" "$ACTUAL_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT"
    TEST_PASSED=false
  fi

  echo "Confirming that Placement resource uses 'api.openshift.com/hypershift: true' label"
  EXPECTED_PLACEMENT_HYPERSHIFT_LABEL_COUNT=1
  ACTUAL_PLACEMENT_HYPERSHIFT_LABEL_COUNT=0
  ACTUAL_PLACEMENT_HYPERSHIFT_LABEL_COUNT=$(oc get Placement -n ocm -o json | jq -r .items[].spec | grep "api.openshift.com/hypershift" | grep -c true)
  if [ "$EXPECTED_PLACEMENT_HYPERSHIFT_LABEL_COUNT" != "$ACTUAL_PLACEMENT_HYPERSHIFT_LABEL_COUNT" ]; then
    printf "\nERROR. Expected count of 'api.openshift.com/hypershift: true' labels in Placement resource for SC to be 1. Got:\n%d" "$ACTUAL_PLACEMENT_HYPERSHIFT_LABEL_COUNT"
    TEST_PASSED=false
  fi

  echo "Confirming that Placement resource uses 'api.openshift.com/osdfm-cluster-status: ready' label"
  EXPECTED_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT=1
  ACTUAL_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT=0
  ACTUAL_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT=$(oc get Placement -n ocm -o json | jq -r .items[].spec | grep "api.openshift.com/hypershift" | grep -c true)
  if [ "$EXPECTED_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT" != "$ACTUAL_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT" ]; then
    printf "\nERROR. Expected count of 'api.openshift.com/osdfm-cluster-status: ready' labels in Placement resource for SC to be 1. Got:\n%d" "$ACTUAL_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17818" $TEST_PASSED
}