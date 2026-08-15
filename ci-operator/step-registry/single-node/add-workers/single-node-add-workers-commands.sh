#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function executeUntilSuccess() {
  local CMD="${*}"

  # API server occasionally becomes unavailable, so we repeat command in case of error
  while true; do
    ret=0
    ${CMD} || ret="$?"

    if [[ ret -eq 0 ]]; then
      return $ret
    fi

    echo "$(date -u --rfc-3339=seconds) - Command returned error $ret, retrying..."
  done
}
export -f executeUntilSuccess

function waitFor() {
	local TIMEOUT="${1}"
	local CMD="${*:2}"

	ret=0
	timeout "${TIMEOUT}" bash -c "executeUntilSuccess ${CMD}" || ret="$?"

	# Command timed out
	if [[ ret -eq 124 ]]; then
	echo "$(date -u --rfc-3339=seconds) - Timed out waiting for result of $CMD"
	exit 1
	fi

	return $ret
}

function IncrementWorkerNodes() {

    # Get the first "worker" machineset we can retrieve.
	if ! machineset=`oc get machinesets -n openshift-machine-api | grep worker | head -1 | awk '{print $1}'`; then
		echo "Could not retrieve machinesets">&2;
		exit 1
	fi

	# Get the worker replica count.
	if ! worker_replicas=`oc get machineset $machineset -n openshift-machine-api -ojson | jq .spec.replicas`; then
		echo "Could not get worker replica count" 
		exit 1
	fi

	if ! [[ "$worker_replicas" =~ ^[0-9]+$ ]] ; then
		echo "Worker replica count should be an integer">&2;
		exit 1
	fi

    worker_replicas="$((worker_replicas + 1))"

    oc scale -n openshift-machine-api --replicas=$worker_replicas machineset $machineset
}
export -f IncrementWorkerNodes

function ReplicaScalingCheck() {

	# Wait for the worker to come online
	retryIntervalSeconds=10
	while true
	do
		if ! replicaStatus=$(oc get machinesets -n openshift-machine-api \
			-ojson | jq '.items[]' \
		      | jq 'if .status | has("availableReplicas") then . else . * {"status": {"availableReplicas": 0 }} end' \
		      | jq 'select(.status.availableReplicas != .spec.replicas or .status.replicas != .spec.replicas)' \
		      | jq '{
			  "name": .metadata.name,
			  "expected_replicas": .spec.replicas,
			  "current_replicas": .status.replicas,
			  "current_available_replicas": .status.availableReplicas
		      }'); then
		    echo "Could not retrieve replica status">&2;
			exit 1
		fi
		
		if  [ ! -z "$replicaStatus" ]; then
			echo "Waiting for current_available_replicas to match expected_replicas...Waiting for ${retryIntervalSeconds} seconds before trying again"
			echo "$replicaStatus"
			sleep $retryIntervalSeconds	
		else
			echo "No pending replica synchronisations, moving on..."
			break
		fi
		
	done

}
export -f ReplicaScalingCheck

for i in $(seq 1 ${SNO_WORKER_COUNT}); do
	echo "Adding worker $i..."
	waitFor 1m IncrementWorkerNodes
    waitFor 10m ReplicaScalingCheck
done
