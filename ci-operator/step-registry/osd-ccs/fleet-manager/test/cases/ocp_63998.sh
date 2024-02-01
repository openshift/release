#!/bin/bash

###### Sector predicates to support multiple sectors by labels tests (OCP-63998) ######

function test_labels() 
{
  TEST_PASSED=true
  sc_cluster_id=$(cat "${SHARED_DIR}"/osd-fm-sc-id)
  mc_cluster_id=$(cat "${SHARED_DIR}"/osd-fm-mc-id)

  #Set up region
  OSDFM_REGION=${LEASED_RESOURCE}
  echo "region: ${LEASED_RESOURCE}"
  if [[ "${OSDFM_REGION}" != "ap-northeast-1" ]]; then
    echo "${OSDFM_REGION} is not ap-northeast-1, exit"
    exit 1
  fi

  INITIAL_MC_COUNT=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters  --parameter search="region is '$OSDFM_REGION'" | jq -r .total)
  echo "Management clusters count in tested region: $INITIAL_MC_COUNT"

  INITIAL_MC_SECTOR=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters/"$mc_cluster_id" | jq -r .sector)
  echo "Management cluster id: '$mc_cluster_id' sector: '$INITIAL_MC_SECTOR'"

  INITIAL_SC_SECTOR=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters/"$sc_cluster_id" | jq -r .sector)
  echo "Service cluster: '$sc_cluster_id' sector: '$INITIAL_SC_SECTOR'"

  # confirm that both mc and sc are in the desired sector

  function confirm_sectors () {
    local sector=$1
    echo "Confirming expected sector value: '$sector' for mc/sc clusters"
    MC_SECTOR=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters/"$mc_cluster_id" | jq -r .sector)
    SC_SECTOR=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters/"$sc_cluster_id" | jq -r .sector)
    if [[ "$MC_SECTOR" != "$sector" ]]; then
      echo "ERROR. Management cluster sector should be: '$sector'. Got: '$MC_SECTOR'"
      TEST_PASSED=false
    fi
    if [[ "$SC_SECTOR" != "$sector" ]]; then
      echo "ERROR. Service cluster sector should be: '$sector'. Got: '$SC_SECTOR'"
      TEST_PASSED=false
    fi
  }

  # confirm management cluster count in testing region is the same as the beginning of execution of this test

  function confirm_mc_count () {
    echo "Confirming that management cluster count didn't increase after sector change"
    ACTUAL_COUNT=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters  --parameter search="region is '$OSDFM_REGION'" | jq -r .total)
    if [[ "$ACTUAL_COUNT" != "$INITIAL_MC_COUNT" ]]; then
      echo "ERROR. Mamangement cluster cound should be: $INITIAL_MC_COUNT. Got: $ACTUAL_COUNT"
      TEST_PASSED=false
    fi
  }

  # add label with correct key and value - sector should change
  add_label "label-qetesting-test" "qetesting" "service_clusters" "$sc_cluster_id" false 60

  confirm_sectors "qetesting"

  confirm_mc_count

  # added label should be available on the service cluster
  confirm_labels "service_clusters" "$sc_cluster_id" 1 "label-qetesting-test" "qetesting"

  # added label should not be available on the management cluster
  confirm_labels "management_clusters" "$mc_cluster_id" 0 "" ""

  # remove label
  cleanup_labels "service_clusters" "$sc_cluster_id"

  echo "Sleep for 60 seconds to allow for sector change to complete"
  sleep 60

  # label removal confirmation
  confirm_labels "service_clusters" "$sc_cluster_id" 0 "" ""

  # after the label is removed - sector should be restored to the default value
  confirm_sectors "main"

  confirm_mc_count

  # add label again and confirm its presence and sector change
  add_label "label-qetesting-test" "qetesting" "service_clusters" "$sc_cluster_id"  false 60

  confirm_sectors "qetesting"

  confirm_mc_count

  confirm_labels "service_clusters" "$sc_cluster_id" 1 "label-qetesting-test" "qetesting"

  confirm_labels "management_clusters" "$mc_cluster_id" 0 "" ""

  # sector should not change when adding a label with incorrect key
  add_label "label-qetesting-wrong" "qetesting" "service_clusters" "$sc_cluster_id" false 60

  confirm_labels "service_clusters" "$sc_cluster_id" 2 "label-qetesting-wrong" "qetesting"

  confirm_sectors "qetesting"

  # remove all labels
  cleanup_labels "service_clusters" "$sc_cluster_id"

  # sector should not change when adding a label with incorrect value
  add_label "label-qetesting-test" "qetesting-wrong" "service_clusters" "$sc_cluster_id" false 60

  confirm_labels "service_clusters" "$sc_cluster_id" 1 "label-qetesting-test" "qetesting-wrong"

  confirm_sectors "main"

  # remove all labels
  cleanup_labels "service_clusters" "$sc_cluster_id"

  update_results "OCP-63998" $TEST_PASSED
}