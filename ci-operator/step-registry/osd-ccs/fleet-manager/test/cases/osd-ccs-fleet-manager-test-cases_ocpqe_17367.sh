#!/bin/bash

###### podisolation obo machine pool test (OCPQE-17367) ######

function test_obo_machine_pool () {
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
        MGMT_CLUSTER_MP_HREF="/api/clusters_mgmt/v1/clusters/$MGMT_CLUSTER_ID/machine_pools"
        MGMT_CLUSTER_OBO_MP_COUNT=$(ocm get "$MGMT_CLUSTER_MP_HREF" | jq -r .items[].id | grep -c obo)
        echo "Confirming that 'obo' machine pool count is exactly 1 for cluster with ID: $MGMT_CLUSTER_ID"
        if [ "$MGMT_CLUSTER_OBO_MP_COUNT" -ne 1 ]; then
          echo "ERROR: Expected count of 'obo' machine pools to be 1. Got '$MGMT_CLUSTER_OBO_MP_COUNT'"
          TEST_PASSED=false
        else
          MACHINE_POOL_OUTPUT=$(ocm get "$MGMT_CLUSTER_MP_HREF"/obo-1)
          MP_REPLICAS=$(jq -n "$MACHINE_POOL_OUTPUT" | jq -r .replicas)
          AVAILABILITY_ZONES=$(jq -n "$MACHINE_POOL_OUTPUT" | jq -r '.availability_zones | length')
          echo "Confirming that the number of replicas and availability zones in the obo machine pool is 3"
          if [ "$MP_REPLICAS" -ne 3 ] || [ "$AVAILABILITY_ZONES" -ne 3 ]; then
            echo "ERROR. Expected number of replicas and availability zones in the obo machine pool to be 3 Got:"
            echo "replicas: $MP_REPLICAS"
            echo "availability zones: $AVAILABILITY_ZONES"
            TEST_PASSED=false
          fi
        fi
      fi
    done
  fi
  update_results "OCPQE-17367" $TEST_PASSED
}