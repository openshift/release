#!/bin/bash

###### endpoints tests (OCPQE-16843) ######

function test_endpoints () {
  TEST_PASSED=true
  echo "Querying '/errors' endpoint"
  ERRORS_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/errors)
  ERRORS_LIST_KIND=$(jq -n "$ERRORS_OUTPUT" | jq -r .kind)
  EXPECTED_ERRORS_LIST_KIND="ErrorList"
  echo "Confirming that '/errors' output returns correct kind: '$EXPECTED_ERRORS_LIST_KIND'"
  if [ "$ERRORS_LIST_KIND" != "$EXPECTED_ERRORS_LIST_KIND" ]; then
    echo "ERROR. Incorrect kind returned: '$ERRORS_LIST_KIND'. Expected: '$EXPECTED_ERRORS_LIST_KIND'"
    TEST_PASSED=false
  fi

  ERRORS_SIZE=$(jq -n "$ERRORS_OUTPUT" | jq -r .size)
  echo "Confirming that '/errors' output returns at least one error"
  if [ "$ERRORS_SIZE" -lt 1 ]; then
    echo "ERROR. There should be some errors returned from the /errors endpoint"
    TEST_PASSED=false
  else
    RETURNED_RECORDS_COUNT=$(jq -n "$ERRORS_OUTPUT" | jq -r '.items | length')
    ## Confirm that number of records returned matches .size value
    echo "Checking number of errors returned against declared size"
    if [ "$RETURNED_RECORDS_COUNT" -ne "$ERRORS_SIZE" ]; then
      echo "ERROR. Mismatch in expected size: $ERRORS_SIZE and number of returned errors: $RETURNED_RECORDS_COUNT"
      TEST_PASSED=false
    else 
      ERROR_ID=$(jq -n "$ERRORS_OUTPUT" | jq -r .items[0].id)
      ERROR_HREF=$(jq -n "$ERRORS_OUTPUT" | jq -r .items[0].href)
      echo "Querying '/errors/{id}' endpoint"
      ERROR_OUTPUT=$(ocm get "$ERROR_HREF")
      SINGLE_ERROR_OUTPUT_ID=$(jq -n "$ERROR_OUTPUT" | jq -r .id)
      SINGLE_ERROR_OUTPUT_HREF=$(jq -n "$ERROR_OUTPUT" | jq -r .href)
      SINGLE_ERROR_OUTPUT_KIND=$(jq -n "$ERRORS_OUTPUT" | jq -r .items[0].kind)
      EXPECTED_ERROR_KIND="Error"
      echo "Confirming that '.items[0]' output from /errors output matches error output corresponding to this particular error in '/errors/{id}' output"
      if [ "$ERROR_ID" != "$SINGLE_ERROR_OUTPUT_ID" ] || [ "$ERROR_HREF" != "$SINGLE_ERROR_OUTPUT_HREF" ] || [ "$SINGLE_ERROR_OUTPUT_KIND" != "$EXPECTED_ERROR_KIND" ]; then
        echo "ERROR. Output of first item in errors array should match /errors/id values"
        echo ".items[0] output:"
        echo "$ERRORS_OUTPUT" | jq -r .items[0]
        echo "/errors/id output:"
        echo "$ERROR_OUTPUT"
        TEST_PASSED=false
      fi
    fi
  fi
  
  ## confirming metadata (/api/osd_fleet_mgmt/v1) endpoint works
  echo "Querying metadata endpoint"
  METADATA_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1)
  COLLECTIONS_LENGTH=$(jq -n "$METADATA_OUTPUT" | jq -r '.collections | length')
  echo "Confirming that metadata contains two collections"
  if [ "$COLLECTIONS_LENGTH" -ne 2 ]; then
    echo "ERROR. There should be two collections returned in the metadata endpoint ('/api/osd_fleet_mgmt/v1')"
    TEST_PASSED=false
  else 
    echo "Confirming that endpoints referenced in the metadata output return correct collections"
    for ((i=0; i<"$COLLECTIONS_LENGTH"; i++)); do
      COLLECTION_HREF=$(jq -n "$METADATA_OUTPUT" | jq -r .collections[$i].href)
      COLLECTION_KIND=$(jq -n "$METADATA_OUTPUT" | jq -r .collections[$i].kind)
      echo "Querying $COLLECTION_HREF"
      COLLECTION_OUTPUT=$(ocm get "$COLLECTION_HREF")
      COLLECTION_OUTPUT_KIND=$(jq -n "$COLLECTION_OUTPUT" | jq -r .kind)
      echo "Confirming that returned collection is of correct kind: $COLLECTION_OUTPUT_KIND"
      if [ "$COLLECTION_KIND" != "$COLLECTION_OUTPUT_KIND" ]; then
        echo "ERROR. Expected kind: '$COLLECTION_OUTPUT' didn't match. Got: '$COLLECTION_OUTPUT_KIND' when querying endpoint from metadata.collections[].href"
        TEST_PASSED=false
      fi
    done
  fi

  ## confirming /keys endpoints work
  echo "Getting first available management cluster (if any created)"
  MC_CLUSTERS_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters)
  MC_CLUSTERS_COUNT=$(jq -n "$MC_CLUSTERS_OUTPUT" | jq -r .size)
  if [ "$MC_CLUSTERS_COUNT" -gt 0 ]; then
    MC_CLUSTER_ID=$(jq -n "$MC_CLUSTERS_OUTPUT" | jq -r .items[0].id)
    MC_CLUSTER_HREF=$(jq -n "$MC_CLUSTERS_OUTPUT" | jq -r .items[0].href)
    echo "Getting keys for MC with ID: $MC_CLUSTER_ID"
    MC_CLUSTER_KEYS_OUTPUT=$(ocm get "$MC_CLUSTER_HREF"/keys)
    EXPECTED_KEYS_LIST_KIND="AccessKeyList"
    MC_KEYS_OUTPUT_KIND=$(jq -n "$MC_CLUSTER_KEYS_OUTPUT" | jq -r .kind)
    echo "Confirming that returned collection is of correct kind: $EXPECTED_KEYS_LIST_KIND"
    if [ "$MC_KEYS_OUTPUT_KIND" != "$EXPECTED_KEYS_LIST_KIND" ]; then
      echo "ERROR. Expected kind: '$EXPECTED_KEYS_LIST_KIND' didn't match. Go:t '$MC_KEYS_OUTPUT_KIND' when querying management_clusters/{id}/keys endpoint"
      TEST_PASSED=false
    fi
  else 
    echo "No management_clusters found"
  fi
  update_results "OCPQE-16843" $TEST_PASSED
}