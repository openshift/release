#!/bin/bash

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
    OBO_MACHINESETS_OUTPUT=$(oc get machinesets.machine.openshift.io -A | grep obo)
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
        REGION=$(oc get machinesets.machine.openshift.io "$MS_NAME" -n openshift-machine-api -o json | jq -r .spec.template.spec.providerSpec.value.placement.region) || true
        AZ=$(oc get machinesets.machine.openshift.io "$MS_NAME" -n openshift-machine-api -o json | jq -r .spec.template.spec.providerSpec.value.placement.availabilityZone) || true
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