#!/bin/bash

###### /audit endpoint tests (OCP-67823) ######

function test_audit_endpooint () {
TEST_PASSED=true
  ## confirm /audit endpoints works
  echo "Querying '/audit' endpoint"
  AUDIT_ENDPOINT_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/audit)
  AUDIT_ENDPOINT_KIND=$(jq -n "$AUDIT_ENDPOINT_OUTPUT" | jq -r .kind)
  EXPECTED_AUDIT_LIST_KIND="AuditRecordList"
  if [ "$AUDIT_ENDPOINT_KIND" != "$EXPECTED_AUDIT_LIST_KIND" ]; then
    echo "ERROR. Incorrect kind returned: '$AUDIT_ENDPOINT_KIND'. Expected: '$EXPECTED_AUDIT_LIST_KIND'"
    TEST_PASSED=false
  fi
  AUDIT_RESULTS_COUNT=$(jq -n "$AUDIT_ENDPOINT_OUTPUT" | jq -r .size)
  echo "Checking if any audit results were returned"
  ALLOWED_HTTP_METHODS=("POST" "PATCH" "DELETE")
  if [ "$AUDIT_RESULTS_COUNT" -gt 0 ]; then
    RETURNED_AUDIT_RECORD_COUNT=$(jq -n "$AUDIT_ENDPOINT_OUTPUT" | jq -r '.items | length')
    ## Confirm that number of records returned matches .size value
    echo "Checking number of audit records returned against declared size"
    if [ "$RETURNED_AUDIT_RECORD_COUNT" -ne "$AUDIT_RESULTS_COUNT" ]; then
      echo "ERROR. Mismatch in expected size: $AUDIT_RESULTS_COUNT and number of returned audit records: $RETURNED_AUDIT_RECORD_COUNT"
      TEST_PASSED=false
    else
      AUDIT_RECORD_USERNAME="" # to be re-assigned and reused later
      ## Confirm that each of ther returned errors is representing POST/PATCH/DELETE operation and username + endpoint URI are not empty
      echo "Checking fields validity of each audit record from the first returned page (correct method and kind, and populated username and uri)"
      EXPECTED_AUDIT_RECORD_KIND="AuditRecord"
      for ((i=0; i<"$AUDIT_RESULTS_COUNT"; i++)); do
        ## check kind
        AUDIT_RECORD_KIND=$(jq -n "$AUDIT_ENDPOINT_OUTPUT" | jq -r .items[$i].kind)
        if [ "$AUDIT_RECORD_KIND" != "$EXPECTED_AUDIT_RECORD_KIND" ]; then
          echo "ERROR. Expected kind '$EXPECTED_AUDIT_RECORD_KIND' didn't match. Got: '$AUDIT_RECORD_KIND' in the /audit endpoint returned items"
          TEST_PASSED=false
          break
        fi
        ## check http method
        AUDIT_RECORD_METHOD=$(jq -n "$AUDIT_ENDPOINT_OUTPUT" | jq -r .items[$i].method)
        # shellcheck disable=SC2076 # ignore the warning - this code works as expected
        if ! [[ ${ALLOWED_HTTP_METHODS[*]} =~ "$AUDIT_RECORD_METHOD" ]]; then
          echo "ERROR. Not allowed HTTP method: $AUDIT_RECORD_METHOD in audit records detected"
          TEST_PASSED=false
          break
        fi
        AUDIT_RECORD_URL=$(jq -n "$AUDIT_ENDPOINT_OUTPUT" | jq -r .items[$i].request_uri)
        if [ "$AUDIT_RECORD_URL" == "" ]; then
          echo "ERROR. Expected audit record uri not to be empty"
          TEST_PASSED=false
          break
        fi
        AUDIT_RECORD_USERNAME=$(jq -n "$AUDIT_ENDPOINT_OUTPUT" | jq -r .items[$i].username)
        if [ "$AUDIT_RECORD_USERNAME" == "" ]; then
          echo "ERROR. Expected audit record username not to be empty"
          TEST_PASSED=false
          break
        fi
      done
      ## check query parameters
      ### page parameter
      EXPECTED_SIZE_FOR_PAGE_PARAM_CHECK=0
      VERY_LARGE_PAGE_NUMBER=999999
      echo "Checking /audit endpoint query parameters"
      echo "Checking /audit endpoint 'page' parameter"
      PAGE_PARAMETER_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/audit --parameter="page=$VERY_LARGE_PAGE_NUMBER")
      PAGE_NUMBER=$(jq -n "$PAGE_PARAMETER_OUTPUT" | jq -r .page)
      SIZE_NUMBER=$(jq -n "$PAGE_PARAMETER_OUTPUT" | jq -r .size)
      ITEMS_LENGTH=$(jq -n "$PAGE_PARAMETER_OUTPUT" | jq -r '.items | length')
      if [ "$PAGE_NUMBER" -ne "$VERY_LARGE_PAGE_NUMBER" ] || [ "$SIZE_NUMBER" -ne "$EXPECTED_SIZE_FOR_PAGE_PARAM_CHECK" ] || [ "$ITEMS_LENGTH" != "$EXPECTED_SIZE_FOR_PAGE_PARAM_CHECK" ]; then
        echo "ERROR. When testing page param in /audit endpoint and providing very large page outside of range, returned items length and size should be 0, and page number output should match the page param. Got: "
        echo "$PAGE_PARAMETER_OUTPUT"
        TEST_PASSED=false
      fi
      ### search parameter
      echo "Checking /audit endpoint 'search' parameter"
      SEARCH_PARAM_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/audit --parameter="search=username='$AUDIT_RECORD_USERNAME'")
      SEARCH_PARAM_SIZE=$(jq -n "$SEARCH_PARAM_OUTPUT" | jq -r .size)
      SEARCH_PARAM_USERNAME=$(jq -n "$SEARCH_PARAM_OUTPUT" | jq -r .items[0].username)
      if [ "$SEARCH_PARAM_SIZE" -lt 1 ] || [ "$SEARCH_PARAM_USERNAME" != "$AUDIT_RECORD_USERNAME" ]; then
        echo "ERROR. When searching for an audit record with existing username: $AUDIT_RECORD_USERNAME, the first item should include the username and items length should be greater than 0. Got:"
        echo "$SEARCH_PARAM_OUTPUT"
        TEST_PASSED=false
      fi
      ### size parameter
      echo "Checking /audit endpoint 'size' parameter"
      SIZE_PARAM_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/audit --parameter="size=$SEARCH_PARAM_SIZE")
      SIZE_OUTPUT_SIZE=$(jq -n "$SIZE_PARAM_OUTPUT" | jq -r .size)
      if [ "$SIZE_OUTPUT_SIZE" -ne "$SEARCH_PARAM_SIZE" ]; then
        echo "ERROR. When providing size parameter for /audit endpoint, returned size should match with $SEARCH_PARAM_SIZE. Got: $SIZE_OUTPUT_SIZE"
        TEST_PASSED=false
      fi
      ### order parameter
      echo "Checking /audit endpoint 'order' (asc) parameter"
      ORDER_PARAMETER_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/audit --parameter="order=cluster_id asc")
      ORDER_OUTPUT_ITEMS_COUNT=$(jq -n "$ORDER_PARAMETER_OUTPUT" | jq -r .size)
      echo "Checking that the output of /audit endpoint query is sorted by cluster_id in ascending order"
      for ((i=1; i<"$ORDER_OUTPUT_ITEMS_COUNT"; i++)); do
        PREVIOUS_INDEX=$((i-1))
        CLUSTER_ID=$(jq -n "$ORDER_PARAMETER_OUTPUT" | jq -r .items["$i"].cluster_id)
        PREVIOUS_ITEM_CLUSTER_ID=$(jq -n "$ORDER_PARAMETER_OUTPUT" | jq -r .items["$PREVIOUS_INDEX"].cluster_id)
        if [[ "$PREVIOUS_ITEM_CLUSTER_ID" > "$CLUSTER_ID" ]]; then
          echo "ERROR. Sorting by cluster_id in ascending didn't work. $PREVIOUS_ITEM_CLUSTER_ID should be lexicographically smaller than or equal to $CLUSTER_ID"
          TEST_PASSED=false
          break
        fi
      done
      echo "Checking /audit endpoint 'order' (desc) parameter"
      ORDER_PARAMETER_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/audit --parameter="order=cluster_id desc")
      ORDER_OUTPUT_ITEMS_COUNT=$(jq -n "$ORDER_PARAMETER_OUTPUT" | jq -r .size)
      echo "Checking that the output of /audit endpoint query is sorted by cluster_id in descending order"
      for ((i=1; i<"$ORDER_OUTPUT_ITEMS_COUNT"; i++)); do
        PREVIOUS_INDEX=$((i-1))
        CLUSTER_ID=$(jq -n "$ORDER_PARAMETER_OUTPUT" | jq -r .items["$i"].cluster_id)
        PREVIOUS_ITEM_CLUSTER_ID=$(jq -n "$ORDER_PARAMETER_OUTPUT" | jq -r .items["$PREVIOUS_INDEX"].cluster_id)
        if [[ "$PREVIOUS_ITEM_CLUSTER_ID" < "$CLUSTER_ID" ]]; then
          echo "ERROR. Sorting by cluster_id in descending oorder didn't work. $PREVIOUS_ITEM_CLUSTER_ID should be lexicographically greater than or equal to $CLUSTER_ID"
          TEST_PASSED=false
          break
        fi
      done
    fi
  else 
    echo "No audit results returned"
  fi
  update_results "OCP-67823" $TEST_PASSED
}