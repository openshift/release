#!/bin/bash

###### sts enable MC not able to create awsendpointservice correctly (OCPQE-17965) ######

function test_awsendpointservices_status_output_populated () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Getting list of awsendpointservices items"

  AWS_ENDPOINT_SERVICES_OUTPUT=$(oc get awsendpointservices.hypershift.openshift.io -A -o json | jq -r)
  ITEMS_LENGTH=$(jq -n "$AWS_ENDPOINT_SERVICES_OUTPUT" | jq -r '.items | length')

  if [ "$ITEMS_LENGTH" -eq 0 ]; then
    echo "There should be at least one item returned for 'awsendpointservices.hypershift.openshift.io' after HC was created"
    TEST_PASSED=false
  else
    STATUS_OUTPUT=$(jq -n "$AWS_ENDPOINT_SERVICES_OUTPUT" | jq -r .items[0].status)
    echo "Confirming that awsendpointservices status is populated"
    echo "Confirming that 'dnsNames' array contains at least one item"
    DNS_NAMES_LENGTH=$(jq -n "$STATUS_OUTPUT" | jq -r '.dnsNames | length')
    if [ "$DNS_NAMES_LENGTH" -eq 0 ]; then
      echo "ERROR. Expected 'dnsNames' array to contain at least one item"
      TEST_PASSED=false
    fi
    echo "Confirming that 'conditions' array contains at least one item"
    CONDITIONS_LENGTH=$(jq -n "$STATUS_OUTPUT" | jq -r '.conditions | length')
    if [ "$CONDITIONS_LENGTH" -eq 0 ]; then
      echo "ERROR. Expected 'conditions' array to contain at least one item"
      TEST_PASSED=false
    fi
    echo "Confirming that 'dnsZoneID' field is a non-empty string"
    DNS_ZONE_ID=$(jq -n "$STATUS_OUTPUT" | jq -r '.dnsZoneID') || echo ""
    if [ "$DNS_ZONE_ID" == "" ]; then
      echo "ERROR. Expected 'dnsZoneID' field to be populated"
      TEST_PASSED=false
    fi
    echo "Confirming that 'endpointID' field is a non-empty string"
    ENDPOINT_ID=$(jq -n "$STATUS_OUTPUT" | jq -r '.endpointID') || echo ""
    if [ "$ENDPOINT_ID" == "" ]; then
      echo "ERROR. Expected 'endpointID' field to be populated"
      TEST_PASSED=false
    fi
    echo "Confirming that 'endpointServiceName' field is a non-empty string"
    ENDPOINT_SERVICE_NAME=$(jq -n "$STATUS_OUTPUT" | jq -r '.endpointServiceName') || echo ""
    if [ "$ENDPOINT_SERVICE_NAME" == "" ]; then
      echo "ERROR. Expected 'endpointServiceName' field to be populated"
      TEST_PASSED=false
    fi
  fi

  update_results "OCPQE-17965" $TEST_PASSED
}