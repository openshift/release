#!/bin/bash

###### test serving machine_pools verification (OCPQE-18337) ######

function test_serving_machine_pools () {
  TEST_PASSED=true
  mc_cluster_id=$(cat "${SHARED_DIR}/ocm-mc-id")
  echo "Getting machine pools names for MC with clusters mgmt API ID: $mc_cluster_id"
  MACHINE_POOL_OUTPUT=""
  MACHINE_POOL_OUTPUT=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_cluster_id"/machine_pools | jq -r) || true

  if [ "$MACHINE_POOL_OUTPUT" == "" ]; then
    echo "ERROR. Failed to get machine pools for MC: $mc_cluster_id"
    TEST_PASSED=false
  else
    # get obo subnets and check if two subnets from serving are the first ones only
    echo "Getting obo machine pool to obtain first two subnets"
    OBO_MP=""
    OBO_MP=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_cluster_id"/machine_pools/obo-1) || true
    if [ "$OBO_MP" == "" ]; then
      echo "ERROR. Unable to get obo subnet"
      TEST_PASSED=false
    else
      OBO_MP_FIRST_TWO_AZS=$(jq -n "$OBO_MP" | jq -c .availability_zones[:2])
      MP_COUNT=$(jq -n "$MACHINE_POOL_OUTPUT" | jq -r .size)
      for ((i=0; i<$((MP_COUNT)); i+=1)); do
        MP=$(jq -n "$MACHINE_POOL_OUTPUT" | jq -r .items[$i])
        MP_NAME=$(jq -n "$MP" | jq -r .id)
        # filter out non-serving and check only serving mps
        if [[ "$MP_NAME" =~ "serving" ]] && ! [[ "$MP_NAME" =~ "non" ]]; then
          echo "Confirming that $MP_NAME machine pool has only two subnets and is placed in two AZs"
          MP_SUBNET_COUNT=$(jq -n "$MP" | jq -r '.subnets | length')
          MP_AZ_ARRAY=$(jq -n "$MP" | jq -c '.availability_zones')
          MP_AZ_COUNT=$(jq -n "$MP_AZ_ARRAY" | jq -r '. | length')
          if [ "$MP_AZ_COUNT" -ne "$MP_SUBNET_COUNT" ] || [ "$MP_AZ_COUNT" -ne 2 ]; then
            echo "ERROR. Unexpected machine pool: '$MP_NAME' subnet count: $MP_SUBNET_COUNT or availability count: $MP_AZ_COUNT (expected 2)"
            TEST_PASSED=false
          fi
          if [ "$OBO_MP_FIRST_TWO_AZS" != "$MP_AZ_ARRAY" ]; then
            echo "ERROR. serving machine pool should only be placed in the first two AZs. It was placed in the following: $MP_AZ_ARRAY"
            TEST_PASSED=false
          fi
        fi
      done
    fi
  fi
  update_results "OCPQE-18337" $TEST_PASSED
}