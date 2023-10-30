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
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
if [[ ! -z "${OSDFM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with osdfm offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OSDFM_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token OSDFM_TOKEN!"
  exit 1
fi

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
  mc_cluster_id=$(cat "${ARTIFACT_DIR}"/osd-fm-mc-id)

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

  # add label with specified key/ value to a cluster of specified type and id

  function add_label () {
    local key=$1
    local value=$2
    local cluster_type=$3
    local cluster_id=$4

    echo "Adding label with key: '$key', value: '$value', to cluster with id: '$cluster_id'"

    echo '{"key":"'"${key}"'", "value":"'"${value}"'"}' | ocm post /api/osd_fleet_mgmt/v1/"$cluster_type"/"$cluster_id"/labels

    echo "Waiting 60 seconds for the label to be applied"
    sleep 60
  }

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

  # add label with correct key and value - sector should change
  add_label "label-qetesting-test" "qetesting" "service_clusters" "$sc_cluster_id"

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
  add_label "label-qetesting-test" "qetesting" "service_clusters" "$sc_cluster_id"

  confirm_sectors "qetesting"

  confirm_mc_count

  confirm_labels "service_clusters" "$sc_cluster_id" 1 "label-qetesting-test" "qetesting"

  confirm_labels "management_clusters" "$mc_cluster_id" 0 "" ""

  # sector should not change when adding a label with incorrect key
  add_label "label-qetesting-wrong" "qetesting" "service_clusters" "$sc_cluster_id"

  confirm_labels "service_clusters" "$sc_cluster_id" 2 "label-qetesting-wrong" "qetesting"

  confirm_sectors "qetesting"

  # remove all labels
  cleanup_labels "service_clusters" "$sc_cluster_id"

  # sector should not change when adding a label with incorrect value
  add_label "label-qetesting-test" "qetesting-wrong" "service_clusters" "$sc_cluster_id"

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

# Test all cases and print results

test_monitoring_disabled

test_autoscaler

test_labels

test_endpoints

test_audit_endpooint

test_machinesets_naming

test_host_prefix_podisolation

test_obo_machine_pool

printf "\nPassed tests:\n"
for p in "${PASSED[@]}"; do
  echo "$p"
done

printf "\nFailed tests:\n"
for f in "${FAILED[@]}"; do
  echo "$f"
done
