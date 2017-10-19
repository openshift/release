#!/bin/bash

# Watches pods with the passed in selector. As they become complete, it outputs their log
# Ends when all pods are complete. If a pod fails, then it exits with a -1

set -e

selector="${1}"
container_name="${2:-}"


function usage {
	echo "Watches and outputs the log of a set of pods. Does not terminate until all pods are completed."
	echo "Usage: ${0} PODSELECTOR"
}

if [[ -z "${selector}" ]]; then
	usage
	exit
fi

finished="no"
failedCount=0
totalCount=0
completed_pods=()
while [[ "${finished}" == "no" ]]; do
	read -ra allpods <<< "$(oc get pods -l "${selector}" -o jsonpath='{ range .items[*]}{ .metadata.name }{ ":" }{ .status.phase }{ " " }{ end }')"
	finished="yes"
	for pod in "${allpods[@]}"; do
		IFS=":" read -ra podstatus <<< "${pod}"
		podname="${podstatus[0]}"
		podstate="${podstatus[1]}"
		if [[ "${podstate}" == "Running" || "${podstate}" == "New" || "${podstate}" == "Pending" ]]; then
			finished="no"
			continue
		fi
		logged="no"
		for completed in "${completed_pods[@]}"; do  
			if [[ "${completed}" == "${podname}" ]]; then
				logged="yes"
				break
			fi
		done
		if [[ "${logged}" == "yes" ]]; then
			continue
		fi
		if [[ "${podstate}" != "Succeeded" ]]; then
			failedCount=$(( failedCount + 1 ))
		fi
		totalCount=$(( totalCount + 1 ))
		completed_pods+=("${podname}")
		if [[ -n "${container_name}" ]]; then
			oc log "${podname}" -c "${container_name}"
		else
			oc log "${podname}"
		fi
	done
	if [[ "${finished}" == "yes" ]]; then 
		break
	fi
	sleep 10
done

if (( failedCount > 0 )); then
	echo "FAIL: ${failedCount} of ${totalCount} tests failed"
	exit 1
fi

echo "SUCCESS: ${totalCount} tests passed"
