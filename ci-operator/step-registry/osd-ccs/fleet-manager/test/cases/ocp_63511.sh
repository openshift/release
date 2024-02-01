#!/bin/bash

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