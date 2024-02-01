#!/bin/bash

###### HCP: Management cluster request-serving pool autoscaling (OCPQE-18303) ######

function test_mc_request_serving_pool_autoscaling () {
  TEST_PASSED=true
  MP_COUNT=0
  mc_cluster_id=$(cat "${SHARED_DIR}/ocm-mc-id")
  fm_mc_cluster_id=$(cat "${SHARED_DIR}/osd-fm-mc-id")
  function get_serving_mp_count () {
    MP_COUNT=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_cluster_id"/machine_pools | jq -r .items[].id | grep serving | grep -v non-serving | sort -V | wc -l )
  }

  function confirm_mp_count () {
    EXPECTED_COUNT=$1
    echo "Confirming that the expected machine pools count is: $EXPECTED_COUNT"
    if [ "$MP_COUNT" -ne "$EXPECTED_COUNT" ]; then
      echo "ERROR. Expected mp count should be $EXPECTED_COUNT mps. Got: $MP_COUNT"
      TEST_PASSED=false
    fi
  }

  EXPECTED_MP_COUNT=11 # 10 initial + 1 for already created HC
  MAXIMUM_MP_COUNT=64

  echo "Getting serving machine pool count for MC with osd clusters mgmt ID: $mc_cluster_id"
  
  get_serving_mp_count

  echo "Confirming mp count with one HC and no mp count buffer labels added"

  confirm_mp_count "$EXPECTED_MP_COUNT"

  confirm_labels "management_clusters" "$fm_mc_cluster_id" 0 "" ""

  SERVING_MP_MINIMUM_WARMUP_KEY="serving-mp-min-warmup"
  MGMT_CLUSTER_TYPE="management_clusters"

  # label value cannot be negative
  add_label "$SERVING_MP_MINIMUM_WARMUP_KEY" "-1" "$MGMT_CLUSTER_TYPE" "$fm_mc_cluster_id" true 0

  confirm_labels "management_clusters" "$fm_mc_cluster_id" 0 "" ""

  # label value cannot be empty
  add_label "$SERVING_MP_MINIMUM_WARMUP_KEY" "" "$MGMT_CLUSTER_TYPE" "$fm_mc_cluster_id" true 0

  confirm_labels "management_clusters" "$fm_mc_cluster_id" 0 "" ""

  # label value cannot be decimal point number 
  add_label "$SERVING_MP_MINIMUM_WARMUP_KEY" "0.1" "$MGMT_CLUSTER_TYPE" "$fm_mc_cluster_id" true 0

  confirm_labels "management_clusters" "$fm_mc_cluster_id" 0 "" ""

  # # add a label with correct key and value, mps should be scaled up to maximum count (64)
  add_label "$SERVING_MP_MINIMUM_WARMUP_KEY" "100" "$MGMT_CLUSTER_TYPE" "$fm_mc_cluster_id" false 240

  confirm_labels "management_clusters" "$fm_mc_cluster_id" 1 "$SERVING_MP_MINIMUM_WARMUP_KEY" "100"

  get_serving_mp_count

  confirm_mp_count "$MAXIMUM_MP_COUNT"

  cleanup_labels "management_clusters" "$fm_mc_cluster_id"

  function scale_down_mps () {
    echo "Scaling down autoscaled machine pools"
    for i in {12..64}
    do
      MP_NAME="serving-$i"
      echo "scale down $MP_NAME machine pool"
      ocm delete "/api/clusters_mgmt/v1/clusters/$mc_cluster_id/machine_pools/$MP_NAME" || true
    done
  }

  scale_down_mps

  update_results "OCPQE-18303" $TEST_PASSED
}