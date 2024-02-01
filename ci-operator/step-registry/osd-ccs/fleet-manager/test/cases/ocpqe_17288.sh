#!/bin/bash

###### host_prefix (podisolation) validation test (OCPQE-17288) ######

function test_host_prefix_podisolation () {
  TEST_PASSED=true
  echo "Getting list of management clusters in podisolation sector"
  CLUSTERS=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters --parameter search="sector='podisolation'")
  CLUSTER_NUMBER=$(jq -n "$CLUSTERS" | jq -r .size)
  echo "Found $CLUSTER_NUMBER clusters"
  if [ "$CLUSTER_NUMBER" -gt 0 ]; then
    for ((i=0; i<"$CLUSTER_NUMBER"; i++)); do
      MC_CLUSTER_ID=$(jq -n "$CLUSTERS" | jq -r .items[$i].id)
      CLUSTER_STATUS=$(jq -n "$CLUSTERS" | jq -r .items[$i].status)
      if [ "$CLUSTER_STATUS" != "ready" ]; then
        echo "MC with ID: $MC_CLUSTER_ID is not ready"
      else
        MGMT_CLUSTER_ID=$(jq -n "$CLUSTERS" | jq -r .items[$i].cluster_management_reference.cluster_id)
        MGMT_CLUSTER_HREF=$(jq -n "$CLUSTERS" | jq -r .items[$i].cluster_management_reference.href)
        echo "Getting network configuration for MC with cluster mgmt ID: $MGMT_CLUSTER_ID"
        HOST_PREFIX=$(ocm get "$MGMT_CLUSTER_HREF" | jq -r .network.host_prefix)
        echo "Confirming that host_prefix of the MC is '24'"
        if [ "$HOST_PREFIX" -ne 24 ]; then
          echo "Expected host_prefix of the MC to be '24'. Got '$HOST_PREFIX'"
          TEST_PASSED=false
        fi
      fi
    done
  fi
  update_results "OCPQE-17288" $TEST_PASSED
}