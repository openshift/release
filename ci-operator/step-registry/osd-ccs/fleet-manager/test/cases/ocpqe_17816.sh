#!/bin/bash

###### Add labels to MC&SC after provision tests (OCPQE-17816) ######

function test_add_labels_to_sc_after_installing () {
  TEST_PASSED=true
  sc_cluster_id=$(cat "${SHARED_DIR}/ocm-sc-id")
  mc_cluster_id=$(cat "${SHARED_DIR}/ocm-mc-id")
  
  echo "Confirming that 'ext-hypershift.openshift.io/cluster-type' label is set to 'service-cluster' for SC with ID: $sc_cluster_id"
  EXPECTED_SC_LABEL="service-cluster"
  ACTUAL_SC_LABEL=$(ocm get /api/clusters_mgmt/v1/clusters/"$sc_cluster_id"/external_configuration/labels | jq -r .items[] | jq 'select(.key == ("ext-hypershift.openshift.io/cluster-type"))' | jq -r .value)

  if [ "$EXPECTED_SC_LABEL" != "$ACTUAL_SC_LABEL" ]; then
    printf "\nERROR. Expected 'ext-hypershift.openshift.io/cluster-type' for SC to be 'service-cluster'. Got:\n%s" "$ACTUAL_SC_LABEL"
    TEST_PASSED=false
  fi

  echo "Confirming that 'ext-hypershift.openshift.io/cluster-type' label is set to 'management-cluster' for MC with ID: $mc_cluster_id"
  EXPECTED_MC_LABEL="management-cluster"
  ACTUAL_MC_LABEL=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_cluster_id"/external_configuration/labels | jq -r .items[] | jq 'select(.key == ("ext-hypershift.openshift.io/cluster-type"))' | jq -r .value)

  if [ "$EXPECTED_MC_LABEL" != "$ACTUAL_MC_LABEL" ]; then
    printf "\nERROR. Expected 'ext-hypershift.openshift.io/cluster-type' for MC to be 'management-cluster'. Got:\n%s" "$ACTUAL_MC_LABEL"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17816" $TEST_PASSED
}