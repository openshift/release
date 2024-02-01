#!/bin/bash

###### MCs/SCs are created as OSD or ROSA STS clusters tests (OCPQE-17867) ######

function test_sts_mc_sc () {
  TEST_PASSED=true
  mc_cluster_id=$(cat "${SHARED_DIR}/ocm-mc-id")
  sc_cluster_id=$(cat "${SHARED_DIR}/ocm-sc-id")

  function check_sts_enabled () {
    cluster_type=$1
    ocm_cluster_id=$2
    echo "Getting clusters_mgmt API output for $cluster_type: $ocm_cluster_id"
    CLUSTERS_MGMT_API_CLUSTER_OUTPUT=""
    CLUSTERS_MGMT_API_CLUSTER_OUTPUT=$(ocm get /api/clusters_mgmt/v1/clusters/"$ocm_cluster_id") || true

    if [ "$CLUSTERS_MGMT_API_CLUSTER_OUTPUT" == "" ]; then
      echo "ERROR. Failed to get cluster with mgmt cluster ID: $ocm_cluster_id"
      TEST_PASSED=false
    else
      EXPECTED_VALUE="required"
      echo "Confirming that '.aws.ec2_metadata_http_tokens' value for $cluster_type: $ocm_cluster_id is: $EXPECTED_VALUE"
      EC2_METADATA_HTTP_TOKENS_VALUE=$(jq -n "$CLUSTERS_MGMT_API_CLUSTER_OUTPUT" | jq -r .aws.ec2_metadata_http_tokens)
      if [ "$EC2_METADATA_HTTP_TOKENS_VALUE" != "$EXPECTED_VALUE" ]; then
        echo "ERROR. Expected value of '.aws.ec2_metadata_http_tokens' for the MC to be $EXPECTED_VALUE. Got: $EC2_METADATA_HTTP_TOKENS_VALUE"
        TEST_PASSED=false
      fi
      echo "Confirming that '.aws.sts.enabled' value for $cluster_type: $ocm_cluster_id is: set to true"
      STS_ENABLED=false
      STS_ENABLED=$(jq -n "$CLUSTERS_MGMT_API_CLUSTER_OUTPUT" | jq -r .aws.sts.enabled) || true
      if [ "$STS_ENABLED" = false ]; then
        echo "ERROR. Expected '.aws.sts.enabled' for the MC to be set to 'true'"
        TEST_PASSED=false
      fi
    fi
  }

  check_sts_enabled "MC" "$mc_cluster_id"

  check_sts_enabled "SC" "$sc_cluster_id"

  update_results "OCPQE-17867" $TEST_PASSED
}