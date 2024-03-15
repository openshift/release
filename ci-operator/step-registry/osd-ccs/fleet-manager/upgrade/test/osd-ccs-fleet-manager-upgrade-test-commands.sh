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
  ocm login --url https://api.integration.openshift.com --token "${OSDFM_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token OSDFM_TOKEN!"
  exit 1
fi

###### test OSDFM should set label with 60% of node memory limit as label (OCM-6666) ######

function test_memory_node_limit_labels () {
  TEST_PASSED=true
  # TODO - run it against ap-northeast-1 once this configuration is enabled by default
  echo "Getting list of management clusters with various mp sizes configuration"
  MCS=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters --parameter search="sector='multi-serving-machine-pools'")
  MCS_NUMBER=$(jq -n "$MCS" | jq -r .total)
  for ((i=0; i<$((MCS_NUMBER)); i+=1)); do
    MC_STATUS=$(jq -n "$MCS" | jq -r .items[$i].status)
    MC_OCM_CLUSTER_ID=$(jq -n "$MCS" | jq -r .items[$i].cluster_management_reference.cluster_id)
    if [ "$MC_STATUS" == "ready" ]; then
      echo "Getting kubeconfig of MC with ocm cluster ID: $MC_OCM_CLUSTER_ID"
      ocm get /api/clusters_mgmt/v1/clusters/"$MC_OCM_CLUSTER_ID"/credentials | jq -r .kubeconfig > "$SHARED_DIR/mc"
      echo "Getting machinesets of MC with ocm cluster ID: $MC_OCM_CLUSTER_ID"
      MS_OUTPUT=$(oc --kubeconfig "$SHARED_DIR/mc" get machinesets.machine.openshift.io -A -o json | jq -r)
      MS_COUNT=$(jq -n "$MS_OUTPUT" | jq -r '.items | length')
      for ((c=0; c<$((MS_COUNT)); c+=1)); do
        MACHINE_SET_NAME=$(jq -n "$MS_OUTPUT" | jq -r .items[$c].metadata.name)
        echo "Checking $MACHINE_SET_NAME machineset label values"
        MACHINE_SET_REQUEST_SERVING_COMPONENT_LABEL_VALUE=$(jq -n "$MS_OUTPUT" | jq -r .items[$c].spec.template.spec.metadata.labels | jq  '."hypershift.openshift.io/request-serving-component" // empty' | xargs)
        MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE=$(jq -n "$MS_OUTPUT" | jq -r .items[$c].spec.template.spec.metadata.labels | jq '."hypershift.openshift.io/request-serving-gomemlimit" // empty' | xargs)
        MACHINE_SET_OSD_FLEET_MANAGER_VALUE=$(jq -n "$MS_OUTPUT" | jq -r .items[$c].spec.template.spec.metadata.labels | jq '."osd-fleet-manager" // empty' | xargs)
        MACHINE_SET_CLUSTER_SIZE_VALUE=$(jq -n "$MS_OUTPUT" | jq -r .items[$c].spec.template.spec.metadata.labels | jq '."hypershift.openshift.io/cluster-size" // empty' | xargs)
        echo "Label 'hypershift.openshift.io/request-serving-component': $MACHINE_SET_REQUEST_SERVING_COMPONENT_LABEL_VALUE"
        echo "label 'hypershift.openshift.io/request-serving-gomemlimit': $MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE"
        echo "label 'osd-fleet-manager': $MACHINE_SET_OSD_FLEET_MANAGER_VALUE"
        echo "label 'hypershift.openshift.io/cluster-size': $MACHINE_SET_CLUSTER_SIZE_VALUE"
        if [[ $MACHINE_SET_NAME == *"infra"* ]] || [[ $MACHINE_SET_NAME == *"worker"* ]]; then
          if [ "$MACHINE_SET_REQUEST_SERVING_COMPONENT_LABEL_VALUE" != "" ] || [ "$MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE" != "" ] || [ "$MACHINE_SET_OSD_FLEET_MANAGER_VALUE" != "" ] || [ "$MACHINE_SET_CLUSTER_SIZE_VALUE" != "" ]; then
            echo "ERROR. Metadata labels should be empty for infra/worker machinesets (see values above)"
            TEST_PASSED=false
          fi
        fi
        if [[ $MACHINE_SET_NAME == *"non-serving"* ]] || [[ $MACHINE_SET_NAME == *"obo-"* ]]; then
          if [ "$MACHINE_SET_REQUEST_SERVING_COMPONENT_LABEL_VALUE" != "" ] || [ "$MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE" != "" ] || ! [ "$MACHINE_SET_OSD_FLEET_MANAGER_VALUE" ] || [ "$MACHINE_SET_CLUSTER_SIZE_VALUE" != "" ]; then
            echo "ERROR. non-serving/obo machineset should only have 'osd-fleet-manager' metadata label set to true (see values above)"
            TEST_PASSED=false
          fi
        fi
        if [[ $MACHINE_SET_NAME == *"serving"* ]] && [[ $MACHINE_SET_NAME != *"non-serving"* ]]; then
          if ! [ "$MACHINE_SET_OSD_FLEET_MANAGER_VALUE" ] || ! [ "$MACHINE_SET_REQUEST_SERVING_COMPONENT_LABEL_VALUE" ]; then
            echo "ERROR. serving machineset should have 'osd-fleet-manager' and 'hypershift.openshift.io/request-serving-component' metadata labels set to true (see values above)"
            TEST_PASSED=false
          fi
          case $MACHINE_SET_CLUSTER_SIZE_VALUE in
            "large")
              if [ "$MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE" != "157286MiB" ]; then
                echo "ERROR. Expecting 'hypershift.openshift.io/request-serving-gomemlimit' label value to be '157286MiB''. Found: $MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE"
                TEST_PASSED=false
                break
              fi
              ;;

            "medium")
              if [ "$MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE" != "78643MiB" ]; then
                echo "ERROR. Expecting 'hypershift.openshift.io/request-serving-gomemlimit' label value to be '157286MiB''. Found: $MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE"
                TEST_PASSED=false
                break
              fi
              ;;

            "small")
              if [ "$MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE" != "9830MiB" ]; then
                echo "ERROR. Expecting 'hypershift.openshift.io/request-serving-gomemlimit' label value to be '157286MiB''. Found: $MACHINE_SET_REQUEST_SERVING_GOMEMLIMIT_LABEL_VALUE"
                TEST_PASSED=false
                break
              fi
              ;;
            *)
              echo "ERROR. Unexpected 'hypershift.openshift.io/cluster-size' value found: '$MACHINE_SET_CLUSTER_SIZE_VALUE'"
              TEST_PASSED=false
          esac
        fi
      done
    fi
  done
  update_results "OCM-6666" $TEST_PASSED
}

###### end of test OSDFM should set label with 60% of node memory limit as label (OCM-6666) ######

test_memory_node_limit_labels

printf "\nPassed tests:\n"
for p in "${PASSED[@]}"; do
  echo "$p"
done

printf "\nFailed tests:\n"
for f in "${FAILED[@]}"; do
  echo "$f"
done
