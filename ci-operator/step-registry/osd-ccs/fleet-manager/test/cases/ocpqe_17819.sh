#!/bin/bash

###### Fix: Unable to fetch cluster details via the API test (OCPQE-17819) ######

function test_fetching_cluster_details_from_api () {
  TEST_PASSED=true

  function compare_jq_filter_values () {
    CLUSTER_DETAILS_FROM_ARRAY=$1
    CLUSTER_DETAILS_FROM_OCM=$2
    EXPECTED_FIELDS_JQ_FILTER=$3
    for filter in "${EXPECTED_FIELDS_JQ_FILTER[@]}"
    do
      ARRAY_ITEM=$(jq -n "$CLUSTER_DETAILS_FROM_ARRAY" | jq -r "$filter")
      CLUSTER_ITEM=$(jq -n "$CLUSTER_DETAILS_FROM_OCM" | jq -r "$filter")
      if [ "$ARRAY_ITEM" != "$CLUSTER_ITEM" ] || [ "$ARRAY_ITEM" == "" ]; then
        echo "ERROR. Expected $filter value for cluster to be the same for list clusters item and when getting clusters/{id} details and not be empty"
        printf "\n. list clusters item: %s : clusters/{id} item: %s" "$ARRAY_ITEM" "$CLUSTER_ITEM"
        TEST_PASSED=false
      fi
    done
  }

  function compare_kind () {
    ACTUAL_KIND=$1
    EXPECTED_KIND=$2
    ERROR_MESSAGE_PARAM=$3
    if [ "$ACTUAL_KIND" != "$EXPECTED_KIND" ]; then
      echo "ERROR. Expected $ERROR_MESSAGE_PARAM kind to be: '$EXPECTED_KIND'. Got: '$ACTUAL_KIND'"
      TEST_PASSED=false
    fi
  }

  function check_mc_fields () {
    CLUSTER_DETAILS_FROM_ARRAY=$1
    CLUSTER_DETAILS_FROM_OCM=$2
    EXPECTED_PARENT_KIND="ServiceCluster"
    EXPECTED_KIND="ManagementCluster"
    ACTUAL_KIND=$(jq -n "$CLUSTER_DETAILS_FROM_ARRAY" | jq -r .kind)
    ACTUAL_NAME=$(jq -n "$CLUSTER_DETAILS_FROM_ARRAY" | jq -r .name)
    ACTUAL_PARENT_KIND=$(jq -n "$CLUSTER_DETAILS_FROM_ARRAY" | jq -r .parent.kind)
    EXPECTED_NAME_PREFIX="hs-mc"
    echo "Confirming that the MC cluster kind is correct"
    compare_kind "$ACTUAL_KIND" "$EXPECTED_KIND" "MC"
    echo "Confirming that the MC parent cluster kind is correct"
    compare_kind "$ACTUAL_PARENT_KIND" "$EXPECTED_PARENT_KIND" "MC parent"
    echo "Confirming that the MC name prefix is correct"
    if ! case $EXPECTED_NAME_PREFIX in "$ACTUAL_NAME") false;; esac; then
      echo "ERROR. Expected MC name to start with: '$EXPECTED_NAME_PREFIX'. Got the following name: '$ACTUAL_NAME'"
      TEST_PASSED=false
    fi
    EXPECTED_FIELDS_JQ_FILTER=(".parent.id" ".parent.href" ".parent.kind")
    compare_jq_filter_values "$CLUSTER_DETAILS_FROM_ARRAY" "$CLUSTER_DETAILS_FROM_OCM" "${EXPECTED_FIELDS_JQ_FILTER[@]}"
  }

  function check_sc_fields () {
    CLUSTER_DETAILS_FROM_ARRAY=$1
    CLUSTER_DETAILS_FROM_OCM=$2
    ACTUAL_KIND=$(jq -n "$CLUSTER_DETAILS_FROM_ARRAY" | jq -r .kind)
    ACTUAL_NAME=$(jq -n "$CLUSTER_DETAILS_FROM_ARRAY" | jq -r .name)
    EXPECTED_KIND="ServiceCluster"
    EXPECTED_NAME_PREFIX="hs-sc"
    echo "Confirming that the SC cluster kind is correct"
    compare_kind "$ACTUAL_KIND" "$EXPECTED_KIND" "SC"
    echo "Confirming that the SC name prefix is correct"
    if ! case $EXPECTED_NAME_PREFIX in "$ACTUAL_NAME") false;; esac; then
      echo "ERROR. Expected SC name to start with: '$EXPECTED_NAME_PREFIX'. Got the following name: '$ACTUAL_NAME'"
      TEST_PASSED=false
    fi

    EXPECTED_FIELDS_JQ_FILTER=(".provision_shard_reference.id" ".provision_shard_reference.href")
    compare_jq_filter_values "$CLUSTER_DETAILS_FROM_ARRAY" "$CLUSTER_DETAILS_FROM_OCM" "${EXPECTED_FIELDS_JQ_FILTER[@]}"
  }

  function check_common_clusters_fields () {
    CLUSTER_DETAILS_FROM_ARRAY=$1
    CLUSTER_DETAILS_FROM_OCM=$2
    # ignore .updated_timestamp (there is a small possibility to have it out of sync between calling the clusters list and cluster/id)
    EXPECTED_FIELDS_JQ_FILTER=(".id" ".href" ".kind" ".name" ".status" ".cloud_provider" ".region" ".cluster_management_reference.cluster_id" ".cluster_management_reference.href" ".name" ".creation_timestamp" ".sector")
    compare_jq_filter_values "$CLUSTER_DETAILS_FROM_ARRAY" "$CLUSTER_DETAILS_FROM_OCM" "${EXPECTED_FIELDS_JQ_FILTER[@]}"
  }
  
  echo "Getting list of ready service clusters"
  SC_CLUSTERS=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters --parameter search="status='ready'")
  echo "Getting list of ready management clusters"
  MC_CLUSTERS=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters --parameter search="status='ready'")
  SC_CLUSTERS_LENGTH=$(jq -n "$SC_CLUSTERS" | jq -r .size)
  MC_CLUSTERS_LENGTH=$(jq -n "$MC_CLUSTERS" | jq -r .size)
  # check fields for SC clusters list
  for ((i=0; i<"$SC_CLUSTERS_LENGTH"; i++)); do
    CLUSTER_DETAILS=$(jq -n "$SC_CLUSTERS" | jq -r .items[$i])
    CLUSTER_ID=$(jq -n "$SC_CLUSTERS" | jq -r .items[$i].id)
    CLUSTER_HREF=$(jq -n "$SC_CLUSTERS" | jq -r .items[$i].href)
    echo "Getting SC cluster/{id} via OCM and confirming that the values correspond to the cluster's values from the clusters list endpoint output"
    CLUSTER_DETAILS_FROM_OCM=$(ocm get "$CLUSTER_HREF")
    echo "Checking that fields returned in the API for SC: $CLUSTER_ID are matching the fields returned from clusters/{id} ocm and are non-empty"
    check_common_clusters_fields "$CLUSTER_DETAILS" "$CLUSTER_DETAILS_FROM_OCM"
    check_sc_fields "$CLUSTER_DETAILS" "$CLUSTER_DETAILS_FROM_OCM"
  done
  # check common fields for MC clusters list
  for ((i=0; i<"$MC_CLUSTERS_LENGTH"; i++)); do
    CLUSTER_DETAILS=$(jq -n "$MC_CLUSTERS" | jq -r .items[$i])
    CLUSTER_ID=$(jq -n "$MC_CLUSTERS" | jq -r .items[$i].id)
    CLUSTER_HREF=$(jq -n "$MC_CLUSTERS" | jq -r .items[$i].href)
    echo "Getting MC cluster/{id} via OCM and confirming that the values correspond to the cluster's values from the clusters list endpoint output"
    CLUSTER_DETAILS_FROM_OCM=$(ocm get "$CLUSTER_HREF")
    echo "Checking that fields returned in the API for MC: $CLUSTER_ID are matching the fields returned from clusters/{id} ocm and are non-empty"
    check_common_clusters_fields "$CLUSTER_DETAILS" "$CLUSTER_DETAILS_FROM_OCM"
    check_mc_fields "$CLUSTER_DETAILS" "$CLUSTER_DETAILS_FROM_OCM"
  done

  update_results "OCPQE-17819" $TEST_PASSED
}