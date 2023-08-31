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

# Test all cases and print results

test_monitoring_disabled

test_autoscaler

test_labels

printf "\nPassed tests:\n"
for p in "${PASSED[@]}"; do
  echo "$p"
done

printf "\nFailed tests:\n"
for f in "${FAILED[@]}"; do
  echo "$f"
done
