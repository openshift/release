#!/bin/bash

function login_to_ocm () {
  # Log in with OSDFM token
  OCM_VERSION=$(ocm version)
  OSDFM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/fleetmanager-token")
  if [[ ! -z "${OSDFM_TOKEN}" ]]; then
    echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OSDFM_TOKEN}"
    if [ $? -ne 0 ]; then
      echo "Login failed"
      exit 1
    fi
  else
    echo "Cannot login! You need to specify the offline token OSDFM_TOKEN!"
    exit 1
  fi
}

# add failed/ passed test cases
function update_results ()
{
  test_case=$1
  result=$2
  if [ "$result" = true ]; then
    PASSED+=("$test_case")
  else
    FAILED+=("$test_case")
  fi
}

# add label with specified key/ value to a cluster of specified type and id
function add_label () {
  local key=$1
  local value=$2
  local cluster_type=$3
  local cluster_id=$4
  local failure_expected=$5
  local sleep=$6

  echo "Adding label with key: '$key', value: '$value', to cluster with id: '$cluster_id'"

  echo '{"key":"'"${key}"'", "value":"'"${value}"'"}' | ocm post /api/osd_fleet_mgmt/v1/"$cluster_type"/"$cluster_id"/labels || true

  if [ "$failure_expected" = true ]; then
    echo "Expecting label addition to fail. Not waiting before it will be applied"
  else
    echo "Waiting $sleep seconds for the label to be applied"
    sleep "$sleep"
  fi
}

# confirm count of labels on a cluster and key/value label match when count > 0
function confirm_labels () {
  local cluster_type=$1
  local cluster_id=$2
  local count=$3
  local key=$4
  local value=$5

  echo "Confirming correct state of labels for cluster with id: '$cluster_id'"

  LABELS_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/"$cluster_type"/"$cluster_id"/labels)
  LABELS_COUNT=$(echo "$LABELS_OUTPUT" | jq -r .total)
  if [[ "$LABELS_COUNT" -gt "$count" ]]; then
    echo "ERROR. Expected labels count for $cluster_type with $cluster_id to be $count. Got: $LABELS_COUNT"
    TEST_PASSED=false
  fi
  if [ "$LABELS_COUNT" -gt 0 ]; then
    echo "Attempting to find expected label with key: '$key' and value: '$value'"
    KEY_MATCH=$(ocm get /api/osd_fleet_mgmt/v1/"$cluster_type"/"$cluster_id"/labels | grep -c "$key")
    if [[ "$KEY_MATCH" -lt 1 ]]; then
      echo "ERROR. Expected previously added label key: '$key' to be returned in labels, but none was found"
      TEST_PASSED=false
    fi
    VALUE_MATCH=$(ocm get /api/osd_fleet_mgmt/v1/"$cluster_type"/"$cluster_id"/labels | grep -c "$value")
    if [[ "$VALUE_MATCH" -lt 1 ]]; then
      echo "ERROR. Expected previously added label value: '$value' to be returned in labels, but none was found"
      TEST_PASSED=false
    fi
  fi
}

# remove all labels for particular cluster
function cleanup_labels ()
{
  local cluster_type=$1
  local cluster_id=$2

  echo "Removing all labels from cluster with id: '$cluster_id'"

  LABELS_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/"$cluster_type"/"$cluster_id"/labels)
  LABELS_COUNT=$(echo "$LABELS_OUTPUT" | jq -r .total)
  while [ "$LABELS_COUNT" -gt 0 ]
  do
    LABEL_ID=$(echo "$LABELS_OUTPUT" | jq -r .items[0].id)
    echo "Removing label with id: '$LABEL_ID' for $cluster_type with id: '$cluster_id'"
    ocm delete /api/osd_fleet_mgmt/v1/"$cluster_type"/"$cluster_id"/labels/"$LABEL_ID"
    sleep 15
    LABELS_OUTPUT=$(ocm get /api/osd_fleet_mgmt/v1/"$cluster_type"/"$cluster_id"/labels)
    LABELS_COUNT=$(echo "$LABELS_OUTPUT" | jq -r .total)
  done
}

function print_results ()
{
  printf "\nPassed tests:\n"
  for p in "${PASSED[@]}"; do
    echo "$p"
  done

  printf "\nFailed tests:\n"
  for f in "${FAILED[@]}"; do
    echo "$f"
  done
}