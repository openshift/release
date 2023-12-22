#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# two arrays used at the end of the script to print out failed/ passed test cases
PASSED=("")
FAILED=("")

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
cleanup_labels () 
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

###### proportional autoscaler tests (OCP-63511) ######
## NOTE - to be executed against a management cluster

function test_autoscaler ()
{
  TEST_PASSED=true

  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  # get overprovisioning configmap json
  OVERPROVISIONING_CM=$(oc get configmap overprovisioning -n cluster-proportional-autoscaler -o json)

  # get coresToReplicas config"
  CORES_TO_REPLICA=$(jq -n "$OVERPROVISIONING_CM" | jq -r '.data.ladder' | jq -r '.coresToReplicas' | jq -c | jq -r .[] | tr '\n' ' ' )
  echo "coresToReplica comfig detected: '$CORES_TO_REPLICA'"

  # there is no support for 2d array in bash, hence the raw string needs to be processed in another way,
  # e.g. first removing all charactres (apart from digits and spaces)
  FILTERED_CORES=$(echo "$CORES_TO_REPLICA" | sed -e 's/\[//g' -e 's/\]//g' -e 's/\,//g')

  # then the leftover string will be assigned to a 1d array
  read -r -a CORES_ARRAY <<< "$FILTERED_CORES"

  # get address of first worker node
  echo "Checking address of first available worker node"
  NODE_ADDRESS=$(oc get nodes | grep -v -e "," -e "NAME" | head -n 1 | awk '{print $1}')

  # get number of CPUs of a worker node
  NUMBER_OF_WORKER_NDOE_CPUS=$(oc get node "$NODE_ADDRESS" -o json | jq -r .status.capacity.cpu)
  echo "Number of CPUs in the worker node: $NUMBER_OF_WORKER_NDOE_CPUS"

  # determine number of desired overprovisioning replicas based on worker node CPU count
  DESIRED_OVERPROV_REPLICAS=0
  for ((i=0; i<${#CORES_ARRAY[@]}; i+=2)); do
    if [ "${CORES_ARRAY[$i]}" -ge "$NUMBER_OF_WORKER_NDOE_CPUS" ]; then
      # assign i + 1 value of replicas to corresponding cpu cores values
      DESIRED_OVERPROV_REPLICAS="$((${CORES_ARRAY[$i+1]}))"
      break
    fi
  done
  echo "Desired number of overprovisioning replicas given worker node CPU count is: $DESIRED_OVERPROV_REPLICAS"

  # get number of available replicas of overprovisioning deployment
  NO_OF_AVAILABLE_OVERPROVISIONING_DEPL=$(oc get Deployment -A | grep overprovisioning | grep -v 'overprovisioning-autoscaler' | awk '{print $5}')
  echo "Number of available overprovisioning replicas: $NO_OF_AVAILABLE_OVERPROVISIONING_DEPL"

  # get number of overprovisioning replicas from deployment spec
  NO_OF_AVAILABLE_OVERPROVISIONING_DEPL_CONFIG=$(oc get Deployment overprovisioning -n cluster-proportional-autoscaler -o json | jq -r .spec.replicas)
  echo "Number of overprovisioning replicas from overprovisioning deployment spec: $NO_OF_AVAILABLE_OVERPROVISIONING_DEPL_CONFIG"

  echo "Confirming that autoscaler config and available overprovisioning replicas match"
  # confirm that number of available replicas of overprovisioning deployment matches autoscaler config
  if [ "$NO_OF_AVAILABLE_OVERPROVISIONING_DEPL" -ne "$DESIRED_OVERPROV_REPLICAS" ] || [ "$DESIRED_OVERPROV_REPLICAS" -ne "$NO_OF_AVAILABLE_OVERPROVISIONING_DEPL_CONFIG" ]; then
    echo "ERROR. Expected number of overprovisioning replicas: $NO_OF_AVAILABLE_OVERPROVISIONING_DEPL to match deployed replicas: $DESIRED_OVERPROV_REPLICAS and deployment config value: $NO_OF_AVAILABLE_OVERPROVISIONING_DEPL_CONFIG"
    TEST_PASSED=false
  fi

  # get number of available replicas of overprovisioning-autoscaler deployment
  NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL=$(oc get Deployment -A | grep 'overprovisioning-autoscaler' | awk '{print $5}')
  echo "Number of available overprovisioning-autoscaler replicas: $NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL"

  # get number of overprovisioning-autoscaler replicas from deployment spec
  NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL_CONFIG=$(oc get Deployment overprovisioning-autoscaler -n cluster-proportional-autoscaler -o json | jq -r .spec.replicas)
  echo "Number of overprovisioning-autoscaler replicas from overprovisioning deployment spec: $NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL_CONFIG"

  echo "Confirming that autoscaler config and available overprovisioning-autoscaler replicas match"
  # confirm that number of available replicas of overprovisioning-autoscaler deployment matches autoscaler config
  if [ "$NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL_CONFIG" -ne "$NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL" ]; then
    echo "ERROR. Expected number of overprovisioning replicas in the config: $NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL_CONFIG to match available replicas: $NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL"
    TEST_PASSED=false
  fi

  # get number of running pods for overprovisioning deployment
  NO_OF_RUNNING_OVERPROVISIONING_PODS=$(oc get pods -n cluster-proportional-autoscaler | grep -v "autoscaler" | grep -c "Running")
  echo "Number of running overprovisioning pods is: $NO_OF_RUNNING_OVERPROVISIONING_PODS"

  echo "Confirming that autoscaler config and available overprovisioning pods count match"
  # confirm that number or running overprovisioning pods matches deployment config
  if [ "$NO_OF_RUNNING_OVERPROVISIONING_PODS" -ne "$NO_OF_AVAILABLE_OVERPROVISIONING_DEPL_CONFIG" ]; then
    echo "ERROR. Expected number of overprovisioning running pods: $NO_OF_RUNNING_OVERPROVISIONING_PODS to match deployment config value: $NO_OF_AVAILABLE_OVERPROVISIONING_DEPL_CONFIG"
    TEST_PASSED=false
  fi

  # get number of running pods for overprovisioning-autoscaler deployment
  NO_OF_RUNNING_OVERPROVISIONING_AUTOSCALER_PODS=$(oc get pods -n cluster-proportional-autoscaler | grep "overprovisioning-autoscaler" | grep -c "Running")
  echo "Number of running overprovisioning-autoscaler pods is: $NO_OF_RUNNING_OVERPROVISIONING_AUTOSCALER_PODS"

  echo "Confirming that autoscaler config and available overprovisioning-autoscaler pods count match"
  # confirm that number or running overprovisioning-autoscaler pods matches deployment config
  if [ "$NO_OF_RUNNING_OVERPROVISIONING_AUTOSCALER_PODS" -ne "$NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL_CONFIG" ]; then
    echo "ERROR. Expected number of overprovisioning-autoscaler running pods: $NO_OF_RUNNING_OVERPROVISIONING_AUTOSCALER_PODS to match deployment config value: $NO_OF_AVAILABLE_OVERPROVISIONING_AUTOSCALER_DEPL_CONFIG"
    TEST_PASSED=false
  fi

  # check that cluster-proportional-autoscaler ClusterRoleBinding was created
  echo "Confirming that ClusterRoleBinding for cluster-proportional-autoscaler was created"
  CL_PROP_AUTOSCALER_CRB=$(oc get ClusterRoleBinding -A | grep -c cluster-proportional-autoscaler)
  if [ "$CL_PROP_AUTOSCALER_CRB" -ne 1 ]; then
    echo "ERROR. cluster-proportional-autoscaler ClusterRoleBinding not found"
    TEST_PASSED=false
  fi

  echo "Confirming that ClusterRole for cluster-proportional-autoscaler was created"
  # check that cluster-proportional-autoscaler ClusterRole was created
  CL_PROP_AUTOSCALER_CR=$(oc get ClusterRole -A | grep -c cluster-proportional-autoscaler)
  if [ "$CL_PROP_AUTOSCALER_CR" -ne 1 ]; then
    echo "ERROR. cluster-proportional-autoscaler ClusterRole not found"
    TEST_PASSED=false
  fi

  echo "Confirming that ServiceAccount for cluster-proportional-autoscaler was created"
  # check that cluster-proportional-autoscaler ServiceAccount was created
  CL_PROP_AUTOSCALER_SA=$(oc get ServiceAccount -A | grep -c cluster-proportional-autoscaler)
  if [ "$CL_PROP_AUTOSCALER_SA" -lt 1 ]; then
    echo "ERROR. cluster-proportional-autoscaler Service Accounts not found"
    TEST_PASSED=false
  fi

  # confirm that the default PriorityClass has GLOBAL-DEFAULT flag set to true and VALUE = 0
  DEFAULT_PRIORITY_CLASS=$(oc get PriorityClass -A | grep default | awk '{print $2,$3}')

  echo "Confirming that 'default' PriorityClass has GLOBAL-DEFAULT set to true and value = 0"
  if [[ "$DEFAULT_PRIORITY_CLASS" != *"true"* ]] || [[ "$DEFAULT_PRIORITY_CLASS" != *"0"* ]];then
    echo "ERROR. 'default' PriorityClass should have value 0 and GLOBAL-DEFAULT set to true. Got the value and GLOBAL_DEFAULT: $DEFAULT_PRIORITY_CLASS"
    TEST_PASSED=false
  fi

  # confirm that the default PriorityClass has GLOBAL-DEFAULT flag set to true and VALUE = 0
  OVERPROVISIONING_PRIORITY_CLASS=$(oc get PriorityClass -A | grep overprovisioning | awk '{print $2,$3}')

  echo "Confirming that 'overprovisioning' PriorityClass has GLOBAL-DEFAULT set to false and value = -1"
  if [[ "$OVERPROVISIONING_PRIORITY_CLASS" != *"false"* ]] || [[ "$OVERPROVISIONING_PRIORITY_CLASS" != *"-1"* ]];then
    echo "ERROR. 'overprovisioning' PriorityClass should have value -1 and GLOBAL-DEFAULT set to false. Got the value and GLOBAL_DEFAULT: $OVERPROVISIONING_PRIORITY_CLASS"
    TEST_PASSED=false
  fi
  update_results "OCP-63511" $TEST_PASSED
}

###### end of proportional autoscaler tests (OCP-63511) ######

##############################################################

###### disable workload monitoring tests (OCP-60338) ######

function test_monitoring_disabled ()
{
  TEST_PASSED=true
  function check_monitoring_disabled () 
  {
    echo "Checking workload monitoring disabled for $1"
    # should be more than 0
    DISABLED_MONITORING_CONFIG_COUNT=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep -c "enableUserWorkload: false")
    if [ "$DISABLED_MONITORING_CONFIG_COUNT" -lt 1 ]; then
      echo "ERROR. Workload monitoring should be disabled by default"
      TEST_PASSED=false
    fi
  }

  ## check workload monitoring disabled on a service cluster

  export KUBECONFIG="${SHARED_DIR}/hs-sc.kubeconfig"
  check_monitoring_disabled "service cluster"

  ## check workload monitoring disabled on a management cluster

  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
  check_monitoring_disabled "management cluster"
  update_results "OCP-60338" $TEST_PASSED
}

###### end of disable workload monitoring tests (OCP-60338) ######

##################################################################

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

###### end of Sector predicates to support multiple sectors by labels tests (OCP-63998) ######

##################################################################

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

###### end of endpoints tests (OCPQE-16843) ######

##################################################################

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

###### end of /audit endpoints tests (OCP-67823) ######

##################################################################

###### machinesets naming test (OCP-68154) ######

function test_machinesets_naming () {
  TEST_PASSED=true

  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
  ## get first name of found machineset
  echo "Getting the name of a first available machineset to confirm that its valid"
  MACHINE_SETS_OUTPUT=""
  ## if no machinesets are found, the statement below will not assign anything to the MACHINE_SETS_OUTPUT
  MACHINE_SETS_OUTPUT=$(oc get machinesets -A | grep "serving" | grep -v "non-serving" |  awk '{print $2}' | head -1) || true
  if [[ "$MACHINE_SETS_OUTPUT" != "" ]]; then
    # get suffix of the machineset name (e.g. for 'hs-mc-20bivna6g-wh8nq-serving-9-us-east-1b', the suffix will be 'us-east-1b')
    # it is obtained by trimming everything up to (including) 6th occurence of the '-' symbol
    echo "Confirming that the suffix of the machineset name: '$MACHINE_SETS_OUTPUT' doesn't include too many dashes - indicating double region in its name"
    SUFFIX=$(echo "$MACHINE_SETS_OUTPUT" | cut -d'-' -f7-)
    # if there are more than 4 dashes in the suffix, the name likely contains duplicated AZ in its name, e.g. 'us-east-2a-us-east-2a'
    NUMBER_OF_DASHES=$(grep -o '-' <<<"$SUFFIX" | grep -c .)
    if [ "$NUMBER_OF_DASHES" -gt 4 ]; then
      echo "Incorrect machineset name detected: $MACHINE_SETS_OUTPUT"
      TEST_PASSED=false
    fi
  else
    echo "No machinesets found."
  fi
  update_results "OCP-68154" $TEST_PASSED
}

###### end of machinesets naming test (OCP-68154) ######

##################################################################

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

###### end of host_prefix (podisolation) validation test (OCPQE-17288) ######

##################################################################

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

###### end of podisolation obo machine pool test (OCPQE-17367) ######

##################################################################

###### MC srep-worker-healthcheck MHC check (OCPQE-17157) ######

function test_machine_health_check_config () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Checking MC MHC match expressions operator"
  EXPECTED_MHC_MATCH_EXPRESSIONS_OPERATOR="NotIn"
  ACTUAL_MHC_MATCH_EXPRESSIONS_OPERATOR=""
  ACTUAL_MHC_MATCH_EXPRESSIONS_OPERATOR=$(oc get machinehealthcheck srep-worker-healthcheck -n openshift-machine-api -o json | jq -r .spec.selector.matchExpressions[] | jq 'select(.key == ("machine.openshift.io/cluster-api-machine-role"))' | jq -r .operator) || true

  if [[ "$EXPECTED_MHC_MATCH_EXPRESSIONS_OPERATOR" != "$ACTUAL_MHC_MATCH_EXPRESSIONS_OPERATOR" ]]; then
    echo "ERROR: Expected the matching expressions operator to be '$EXPECTED_MHC_MATCH_EXPRESSIONS_OPERATOR'. Found: '$ACTUAL_MHC_MATCH_EXPRESSIONS_OPERATOR'"
    TEST_PASSED=false
  fi

  echo "Checking that MHC health check excludes 'master' and 'infra' machines"
  EXPECTED_EXCLUDED_IN_MHC=1
  MASTER_MACHINES_EXCLUDED=0
  INFRA_MACHINES_EXCLUDED=0
  WORKER_MACHINES_EXCLUDED=-1
  MASTER_MACHINES_EXCLUDED=$(oc get machinehealthcheck srep-worker-healthcheck -n openshift-machine-api -o json | jq -r .spec.selector.matchExpressions[] | jq 'select(.key == ("machine.openshift.io/cluster-api-machine-role"))' | jq -r .values | grep -c master) || true
  INFRA_MACHINES_EXCLUDED=$(oc get machinehealthcheck srep-worker-healthcheck -n openshift-machine-api -o json | jq -r .spec.selector.matchExpressions[] | jq 'select(.key == ("machine.openshift.io/cluster-api-machine-role"))' | jq -r .values | grep -c infra) || true
  WORKER_MACHINES_EXCLUDED=$(oc get machinehealthcheck srep-worker-healthcheck -n openshift-machine-api -o json | jq -r .spec.selector.matchExpressions[] | jq 'select(.key == ("machine.openshift.io/cluster-api-machine-role"))' | jq -r .values | grep -c worker) || true

  # 1 expecred - master machines should be included in the 'NotIn' mhc operator check
  if [ "$MASTER_MACHINES_EXCLUDED" -ne "$EXPECTED_EXCLUDED_IN_MHC" ]; then
    echo "ERROR: Expected master machines to be included in the 'NotIn' match expression for the MC MHC"
    TEST_PASSED=false
  fi

  # 1 expecred - infra machines should be included in the 'NotIn' mhc operator check
  if [ "$INFRA_MACHINES_EXCLUDED" -ne "$EXPECTED_EXCLUDED_IN_MHC" ]; then
    echo "ERROR: Expected infra machines to be included in the 'NotIn' match expression for the MC MHC"
    TEST_PASSED=false
  fi

  echo "Checking that MHC health check includes 'worker' machines"

  # 0 expecred - worker machines should not be included in the 'NotIn' mhc operator check
  if [ "$WORKER_MACHINES_EXCLUDED" -eq "$EXPECTED_EXCLUDED_IN_MHC" ]; then
    echo "ERROR: Expected worker machines not to be included in the 'NotIn' match expression for the MC MHC"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17157" $TEST_PASSED
}

###### end of MC srep-worker-healthcheck MHC check (OCPQE-17578) ######

##################################################################

###### test fix for 'Pods can be created on MC request serving nodes before taints are applied' (OCPQE-17578) ######

function test_compliance_monkey_descheduler () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Checking that compliance-monkey deployment is present and contains descheduler container"
  EXPECTED_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT=1
  ACTUAL_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT=0
  ACTUAL_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT=$(oc get deployment compliance-monkey -n openshift-compliance-monkey -o json | jq -r .spec.template.spec.containers[].args | grep -c descheduler) || true

  if [ "$EXPECTED_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT" -ne "$ACTUAL_COMPLIANCE_MONKEY_DEPLOYMENT_CONTAINING_DESCHEDULER_COUNT" ]; then
    echo "ERROR: Expected compliance-monkey deployment to be present and containing descheduler container"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17578" $TEST_PASSED
}

###### end of test fix for 'Pods can be created on MC request serving nodes before taints are applied' (OCPQE-17578) ######

##################################################################

###### Stop installing Hypershift CRDs to service clusters tests (OCPQE-17815) ######

function test_hypershift_crds_not_installed_on_sc () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-sc.kubeconfig"
  
  echo "Confirming that hostedcluster and nodepool CRDs are not installed on service cluster"
  EXPECTED_HOSTED_CL_NODEPOOL_CRD_OUTPUT=""
  ACTUAL_HOSTED_CL_NODEPOOL_CRD_OUTPUT=$(oc get crd | grep -E 'hostedcluster|nodepool') || true

  if [ "$EXPECTED_HOSTED_CL_NODEPOOL_CRD_OUTPUT" != "$ACTUAL_HOSTED_CL_NODEPOOL_CRD_OUTPUT" ]; then
    printf "\nERROR. Expected nodepool/hostedcluster CRDs not to be installed on SC. Got:\n%s" "$ACTUAL_HOSTED_CL_NODEPOOL_CRD_OUTPUT"
    TEST_PASSED=false
  fi

  echo "Confirming that hostedcluster resource is not present on service cluster"
  EXPECTED_HOSTED_CL_OUTPUT="error: the server doesn't have a resource type \"hostedcluster\""
  ACTUAL_HOSTED_CL_OUTPUT=$(oc get hostedcluster -A 2>&1 >/dev/null) || true

  if [ "$EXPECTED_HOSTED_CL_OUTPUT" != "$ACTUAL_HOSTED_CL_OUTPUT" ]; then
    printf "\nERROR. Expected hostedcluster resource not to be found on SC. Got:\n%s" "$ACTUAL_HOSTED_CL_OUTPUT"
    TEST_PASSED=false
  fi

  echo "Confirming that nodepool resource is not present on service cluster"
  EXPECTED_NODEPOOL_OUTPUT="error: the server doesn't have a resource type \"nodepool\""
  ACTUAL_NODEPOO_OUTPUT=$(oc get nodepool -A 2>&1 >/dev/null) || true

  if [ "$EXPECTED_NODEPOOL_OUTPUT" != "$ACTUAL_NODEPOO_OUTPUT" ]; then
    printf "\nERROR. Expected nodepool resource not to be found on SC. Got:\n%s" "$ACTUAL_NODEPOO_OUTPUT"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17815" $TEST_PASSED
}

###### end of Stop installing Hypershift CRDs to service clusters tests (OCPQE-17815) ######

##################################################################

###### Add labels to MC&SC after provision tests (OCPQE-17816) ######

function test_add_labels_to_sc_after_installing () {
  TEST_PASSED=true
  sc_cluster_id=$(cat "${SHARED_DIR}/ocm-sc-id")
  mc_cluster_id=$(cat "${SHARED_DIR}/ocm-mc-id")
  
  echo "Confirming that 'ext-hypershift.openshift.io/cluster-type' label is set to 'service-cluster' for SC with ID: $sc_cluster_id"
  EXPECTED_SC_LABEL="service-cluster"
  ACTUAL_SC_LABEL=$(ocm get /api/clusters_mgmt/v1/clusters/"$sc_cluster_id"/external_configuration/labels | jq -r .items[] | jq 'select(.key == ("ext-hypershift.openshift.io/cluster-type"))' | jq -r .value)

  if [ "$EXPECTED_SC_LABEL" != "$ACTUAL_SC_LABEL" ]; then
    printf "\nERROR. Expected 'ext-hypershift.openshift.io/cluster-type' for SC to be 'service-cluster'. Got:\n%s" "$ACTUAL_SC_LABEL"
    TEST_PASSED=false
  fi

  echo "Confirming that 'ext-hypershift.openshift.io/cluster-type' label is set to 'management-cluster' for MC with ID: $mc_cluster_id"
  EXPECTED_MC_LABEL="management-cluster"
  ACTUAL_MC_LABEL=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_cluster_id"/external_configuration/labels | jq -r .items[] | jq 'select(.key == ("ext-hypershift.openshift.io/cluster-type"))' | jq -r .value)

  if [ "$EXPECTED_MC_LABEL" != "$ACTUAL_MC_LABEL" ]; then
    printf "\nERROR. Expected 'ext-hypershift.openshift.io/cluster-type' for MC to be 'management-cluster'. Got:\n%s" "$ACTUAL_MC_LABEL"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17816" $TEST_PASSED
}

###### end of Add labels to MC&SC after provision tests (OCPQE-17816) ######

##################################################################

###### Ensure only ready management clusters are considered in ACM's placement decision test (OCPQE-17818) ######

function test_ready_mc_acm_placement_decision () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-sc.kubeconfig"

  echo "Confirming that api.openshift.com/osdfm-cluster-status is ready in the ManagedCluster resource on SC"
  EXPECTED_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT=1
  ACTUAL_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT=0
  ACTUAL_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT=$(oc get ManagedCluster -o json | grep "\"api.openshift.com/osdfm-cluster-status"\" | grep -c "ready")
  if [ "$EXPECTED_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT" != "$ACTUAL_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT" ]; then
    printf "\nERROR. Expected count of 'api.openshift.com/osdfm-cluster-status: ready' in ManagedCluster resource SC to be 1. Got:\n%d" "$ACTUAL_OSD_FM_CLUSTER_READY_STATUS_LABEL_COUNT"
    TEST_PASSED=false
  fi

  echo "Confirming that Placement resource uses 'api.openshift.com/hypershift: true' label"
  EXPECTED_PLACEMENT_HYPERSHIFT_LABEL_COUNT=1
  ACTUAL_PLACEMENT_HYPERSHIFT_LABEL_COUNT=0
  ACTUAL_PLACEMENT_HYPERSHIFT_LABEL_COUNT=$(oc get Placement -n ocm -o json | jq -r .items[].spec | grep "api.openshift.com/hypershift" | grep -c true)
  if [ "$EXPECTED_PLACEMENT_HYPERSHIFT_LABEL_COUNT" != "$ACTUAL_PLACEMENT_HYPERSHIFT_LABEL_COUNT" ]; then
    printf "\nERROR. Expected count of 'api.openshift.com/hypershift: true' labels in Placement resource for SC to be 1. Got:\n%d" "$ACTUAL_PLACEMENT_HYPERSHIFT_LABEL_COUNT"
    TEST_PASSED=false
  fi

  echo "Confirming that Placement resource uses 'api.openshift.com/osdfm-cluster-status: ready' label"
  EXPECTED_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT=1
  ACTUAL_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT=0
  ACTUAL_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT=$(oc get Placement -n ocm -o json | jq -r .items[].spec | grep "api.openshift.com/hypershift" | grep -c true)
  if [ "$EXPECTED_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT" != "$ACTUAL_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT" ]; then
    printf "\nERROR. Expected count of 'api.openshift.com/osdfm-cluster-status: ready' labels in Placement resource for SC to be 1. Got:\n%d" "$ACTUAL_PLACEMENT_CLUSTER_STATUS_LABEL_COUNT"
    TEST_PASSED=false
  fi

  update_results "OCPQE-17818" $TEST_PASSED
}

###### end of Ensure only ready management clusters are considered in ACM's placement decision tests (OCPQE-17818) ######

##################################################################

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

###### end of Fix: Unable to fetch cluster details via the API tests (OCPQE-17819) ######

##################################################################

###### Create machine pools for request serving HCP components tests (OCPQE-17866) ######

function test_machineset_tains_and_labels () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Getting a name of serving machineset"
  SERVING_MACHINE_SET_NAME=""
  SERVING_MACHINE_SET_NAME=$(oc get machineset -A | grep -e "serving" | grep -v "non-serving" | awk '{print $2}' | head -1) || true
  if [ "$SERVING_MACHINE_SET_NAME" == "" ]; then
    echo "ERROR. Failed to get a name of a serving machineset"
    TEST_PASSED=false
  else
    echo "Getting labels of of serving machineset: $SERVING_MACHINE_SET_NAME and confirming that 'hypershift.openshift.io/request-serving-component' is set to true"
    SERVING_MACHINE_SET_REQUEST_SERVING_LABEL_VALUE=""
    SERVING_MACHINE_SET_REQUEST_SERVING_LABEL_VALUE=$(oc get machineset "$SERVING_MACHINE_SET_NAME" -n openshift-machine-api -o json | jq -r .spec.template.spec.metadata.labels | jq  '."hypershift.openshift.io/request-serving-component"')
    if [ "$SERVING_MACHINE_SET_REQUEST_SERVING_LABEL_VALUE" == "" ] || [ "$SERVING_MACHINE_SET_REQUEST_SERVING_LABEL_VALUE" = false ]; then
      echo "ERROR. 'hypershift.openshift.io/request-serving-component' should be present in machineset labels and set to true. Unable to get the key value pair from labels"
      TEST_PASSED=false
    fi
    echo "Getting tains of of serving machineset: $SERVING_MACHINE_SET_NAME and confirming that 'hypershift.openshift.io/request-serving-component' is set to true"
    SERVING_MACHINE_SET_REQUEST_SERVING_TAINT_VALUE=false
    SERVING_MACHINE_SET_REQUEST_SERVING_TAINT_VALUE=$(oc get machineset "$SERVING_MACHINE_SET_NAME" -n openshift-machine-api -o json | jq -r .spec.template.spec.taints[] | jq 'select(.key == "hypershift.openshift.io/request-serving-component")' | jq -r .value)
    if [ "$SERVING_MACHINE_SET_REQUEST_SERVING_TAINT_VALUE" = false ]; then
      echo "ERROR. 'hypershift.openshift.io/request-serving-component' should be present in machineset taints and set to true. Unable to get the key value pair from taints"
      TEST_PASSED=false
    fi
  fi

  update_results "OCPQE-17866" $TEST_PASSED
}

###### end of Create machine pools for request serving HCP components tests (OCPQE-17866) ######

##################################################################

###### MCs/SCs are created as OSD or ROSA STS clusters tests (OCPQE-17867) ######

function test_sts_mc_sc () {
  TEST_PASSED=true
  mc_cluster_id=$(cat "${SHARED_DIR}/ocm-mc-id")
  sc_cluster_id=$(cat "${SHARED_DIR}/ocm-sc-id")

  function check_sts_enabled () {
    cluster_type=$1
    ocm_cluster_id=$2
    echo "Getting clusters_mgmt API output for $cluster_type: $ocm_cluster_id"
    CLUSTERS_MGMT_API_CLUSTER_OUTPUT=""
    CLUSTERS_MGMT_API_CLUSTER_OUTPUT=$(ocm get /api/clusters_mgmt/v1/clusters/"$ocm_cluster_id") || true

    if [ "$CLUSTERS_MGMT_API_CLUSTER_OUTPUT" == "" ]; then
      echo "ERROR. Failed to get cluster with mgmt cluster ID: $ocm_cluster_id"
      TEST_PASSED=false
    else
      EXPECTED_VALUE="required"
      echo "Confirming that '.aws.ec2_metadata_http_tokens' value for $cluster_type: $ocm_cluster_id is: $EXPECTED_VALUE"
      EC2_METADATA_HTTP_TOKENS_VALUE=$(jq -n "$CLUSTERS_MGMT_API_CLUSTER_OUTPUT" | jq -r .aws.ec2_metadata_http_tokens)
      if [ "$EC2_METADATA_HTTP_TOKENS_VALUE" != "$EXPECTED_VALUE" ]; then
        echo "ERROR. Expected value of '.aws.ec2_metadata_http_tokens' for the MC to be $EXPECTED_VALUE. Got: $EC2_METADATA_HTTP_TOKENS_VALUE"
        TEST_PASSED=false
      fi
      echo "Confirming that '.aws.sts.enabled' value for $cluster_type: $ocm_cluster_id is: set to true"
      STS_ENABLED=false
      STS_ENABLED=$(jq -n "$CLUSTERS_MGMT_API_CLUSTER_OUTPUT" | jq -r .aws.sts.enabled) || true
      if [ "$STS_ENABLED" = false ]; then
        echo "ERROR. Expected '.aws.sts.enabled' for the MC to be set to 'true'"
        TEST_PASSED=false
      fi
    fi
  }

  check_sts_enabled "MC" "$mc_cluster_id"

  check_sts_enabled "SC" "$sc_cluster_id"

  update_results "OCPQE-17867" $TEST_PASSED
}

###### end of MCs/SCs are created as OSD or ROSA STS clusters tests (OCPQE-17867) ######

##################################################################

###### fix: Backups created only once tests (OCPQE-17901) ######

function test_backups_created_only_once () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Getting schedule configuration"
  SCHEDULE_OUTPUT=$(oc get schedule -n openshift-adp-operator | tail -3)
  echo "Confirming that hourly, daily and weekly backups are available, enabled and with correct cron expression"
  echo "$SCHEDULE_OUTPUT" | while read -r line; do
    SCHEDULE_NAME=$(echo "$line" | awk '{print $1}')
    SCHEDULE_ENABLED=$(echo "$line" | awk '{print $2}')
    SCHEDULE_CRON=$(echo "$line" | awk '{print $3 " " $4 " " $5 " " $6 " " $7}')
    if ! [[ "$SCHEDULE_NAME" =~ ^("daily-full-backup"|"hourly-full-backup"|"weekly-full-backup") ]]; then
      echo "Found unexpected name: '$SCHEDULE_NAME'. Expected one of: ['daily-full-backup'|'hourly-full-backup'|'weekly-full-backup']"
      TEST_PASSED=false
      break
    fi
    if [ "$SCHEDULE_ENABLED" != "Enabled" ]; then
      echo "Schedule '$SCHEDULE_NAME' should be set to 'Enabled'. Found: $SCHEDULE_ENABLED"
      TEST_PASSED=false
      break
    fi
    case $SCHEDULE_NAME in

      daily-full-backup)
        if [ "$SCHEDULE_CRON" != "0 1 * * *" ]; then
          echo "Schedule '$SCHEDULE_NAME' should be set to '0 1 * * *'. Found: $SCHEDULE_CRON"
          TEST_PASSED=false
          break
        fi
        ;;

      hourly-full-backup)
        if [ "$SCHEDULE_CRON" != "17 * * * *" ]; then
          echo "Schedule '$SCHEDULE_NAME' should be set to '17 * * * *'. Found: $SCHEDULE_CRON"
          TEST_PASSED=false
          break
        fi
        ;;

      weekly-full-backup)
        if [ "$SCHEDULE_CRON" != "0 2 * * 1" ]; then
          echo "Schedule '$SCHEDULE_NAME' should be set to '0 2 * * 1'. Found: $SCHEDULE_CRON"
          TEST_PASSED=false
          break
        fi
        ;;
    esac
  done

  update_results "OCPQE-17901" $TEST_PASSED
}

###### end of fix: Backups created only once tests (OCPQE-17901) ######

##################################################################

###### fix: Hypershift OBO machineset set to 3 nodes in the same AZ tests (OCPQE-17964) ######

function test_obo_machinesets () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
  mc_cluster_id=$(cat "${SHARED_DIR}/ocm-mc-id")

  echo "Getting 'obo' machinepools names"
  OBO_MACHINE_POOLS_NAMES=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_cluster_id"/machine_pools | jq '.items[]' | jq 'select(.id | startswith("obo"))' | jq -r .id)
  EXPECTED_OBO_MP_COUNT=1
  ACTUAL_OBO_MP_COUNT=$(echo -n "$OBO_MACHINE_POOLS_NAMES" | grep -c '^')
  echo "Confirming that there is only one obo machine pool"

  if [[ "$OBO_MACHINE_POOLS_NAMES" != "obo"* ]] || [ "$ACTUAL_OBO_MP_COUNT" -ne "$EXPECTED_OBO_MP_COUNT" ]; then
    echo "ERROR. Unable to confirm that only one obo machine pool exists. Got the following mps with 'obo' in their name: '$OBO_MACHINE_POOLS_NAMES'"
    TEST_PASSED=false
  else
    echo "Confirming that number of replicas, AZs and subnets for $OBO_MACHINE_POOLS_NAMES matches expectations (3)"
    OBO_MP_OUTPUT=$(ocm get /api/clusters_mgmt/v1/clusters/"$mc_cluster_id"/machine_pools/"$OBO_MACHINE_POOLS_NAMES")
    EXPECTED_MP_REPLICAS=3
    EXPECTED_MP_AZ_COUNT=3
    EXPECTED_MP_SUBNETS_COUNT=3
    ACTUAL_MP_REPLICAS=$(jq -n "$OBO_MP_OUTPUT" | jq -r .replicas) || true
    ACTUAL_MP_SUBNET_COUNT=$(jq -n "$OBO_MP_OUTPUT" | jq -r '.subnets | length') || true
    ACTUAL_MP_AZ_COUNT=$(jq -n "$OBO_MP_OUTPUT" | jq -r '.availability_zones | length') || true
    if [ "$EXPECTED_MP_REPLICAS" -ne "$ACTUAL_MP_REPLICAS" ] || [ "$EXPECTED_MP_AZ_COUNT" -ne "$ACTUAL_MP_AZ_COUNT" ] || [ "$EXPECTED_MP_SUBNETS_COUNT" -ne "$ACTUAL_MP_SUBNET_COUNT" ]; then
      echo "ERROR. Expecting number of replicas, AZs count and subnet count for $OBO_MACHINE_POOLS_NAMES to be 3."
      ech "Got number of replicas: $ACTUAL_MP_REPLICAS, number of AZs: $ACTUAL_MP_AZ_COUNT, subnets: $ACTUAL_MP_SUBNET_COUNT"
      TEST_PASSED=false
    fi
    echo "Getting obo machinesets"
    OBO_MACHINESETS_OUTPUT=$(oc get machinesets -A | grep obo)
    NO_OF_OBO_MACHINESETS=$(echo -n "$OBO_MACHINESETS_OUTPUT" | grep -c '^')
    EXPECTED_NO_OF_OBO_MACHINESETS=3
    if [ "$NO_OF_OBO_MACHINESETS" -ne "$EXPECTED_NO_OF_OBO_MACHINESETS" ]; then
      echo "ERROR. Expected number of obo machinesets to be: $EXPECTED_NO_OF_OBO_MACHINESETS. Got: $NO_OF_OBO_MACHINESETS"
      TEST_PASSED=false
    else
      PREVIOUS_MS_REGION=""
      PREVIOUS_MS_AZ=""
      EXPECTED_DESIRED_REPLICA_COUNT=1
      echo "$OBO_MACHINESETS_OUTPUT" | while read -r ms; do
        MS_NAME=$(echo "$ms" | awk '{print $2}')
        MS_DESIRED_REPLICAS=$(echo "$ms" | awk '{print $3}')
        echo "Confirming that obo machineset $MS_NAME has desired number of replicas ($MS_DESIRED_REPLICAS) and is placed in the same region as other obo ms, but in unique AZ"
        if [ "$MS_DESIRED_REPLICAS" != "$EXPECTED_DESIRED_REPLICA_COUNT" ]; then
          echo "ERROR. Expected desired $MS_NAME desired replica count to be: $EXPECTED_DESIRED_REPLICA_COUNT. Got: $MS_DESIRED_REPLICAS"
          TEST_PASSED=false
          break
        fi
        REGION=$(oc get machineset "$MS_NAME" -n openshift-machine-api -o json | jq -r .spec.template.spec.providerSpec.value.placement.region) || true
        AZ=$(oc get machineset "$MS_NAME" -n openshift-machine-api -o json | jq -r .spec.template.spec.providerSpec.value.placement.availabilityZone) || true
        if [ "$PREVIOUS_MS_REGION" == "" ]; then
          if [ "$REGION" == "" ]; then
            echo "ERROR. Expected machineset: $MS_NAME spec to contain non-empty region. Unable to get this property"
            TEST_PASSED=false
            break
          else
            PREVIOUS_MS_REGION="$REGION"
          fi
        fi
        if [ "$PREVIOUS_MS_AZ" == "$AZ" ] || [ "$AZ" == "" ]; then
          echo "ERROR. Expected machineset: $MS_NAME spec to contain non-empty availability zone that is unique across all obo machinesets. Got value: '$AZ'"
          TEST_PASSED=false
          break
        else
          PREVIOUS_MS_AZ="$AZ"
        fi
      done
    fi
  fi

  update_results "OCPQE-17964" $TEST_PASSED
}

###### end of fix: Hypershift OBO machineset set to 3 nodes in the same AZ tests (OCPQE-17964) ######

##################################################################

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

###### end of fix: sts enable MC not able to create awsendpointservice correctly (OCPQE-17965) ######

##################################################################

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
  add_label "$SERVING_MP_MINIMUM_WARMUP_KEY" "100" "$MGMT_CLUSTER_TYPE" "$fm_mc_cluster_id" false 120

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

###### end of HCP: Management cluster request-serving pool autoscaling (OCPQE-18303) ######

##################################################################

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

###### end of test serving machine_pools verification (OCPQE-18337) ######

# Test all cases and print results

test_monitoring_disabled

# temporarily disabling this test, as autoscaling work is ongoing and it won't pass
# test_autoscaler

test_labels

test_endpoints

test_audit_endpooint

test_machinesets_naming

test_host_prefix_podisolation

test_obo_machine_pool

test_machine_health_check_config

test_compliance_monkey_descheduler

test_hypershift_crds_not_installed_on_sc

test_add_labels_to_sc_after_installing

test_ready_mc_acm_placement_decision

test_fetching_cluster_details_from_api

test_machineset_tains_and_labels

test_sts_mc_sc

test_backups_created_only_once

test_obo_machinesets

test_awsendpointservices_status_output_populated

test_serving_machine_pools

test_mc_request_serving_pool_autoscaling

printf "\nPassed tests:\n"
for p in "${PASSED[@]}"; do
  echo "$p"
done

printf "\nFailed tests:\n"
for f in "${FAILED[@]}"; do
  echo "$f"
done
