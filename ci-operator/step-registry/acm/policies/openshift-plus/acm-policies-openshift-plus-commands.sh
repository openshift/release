#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# cd to writeable directory
cd /tmp/

git clone https://github.com/stolostron/policy-collection.git

sleep 60

cd policy-collection/deploy/
echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -a openshift-plus

sleep 120

# Wait for policies to be compliant
# NOTE: IGNORE_SECONDARY_POLICIES is set via step config YAML (naming deviates from OPP__ convention)
typeset -i retries=40
typeset results=""
typeset notready=""
typeset candidates=""
typeset try=""
typeset -i policyCount=0
for try in $(seq "${retries}"); do
  if ! results=$(oc get policies -n policies); then
    if [ "${try}" -eq "${retries}" ]; then
      : "Error: API request failed on final attempt (${retries} retries exhausted)"
      exit 1
    fi
    : "Try ${try}/${retries}: API request failed, retrying in 30 seconds"
    sleep 30
    continue
  fi
  policyCount=0
  if [[ -n "${results}" ]]; then
    policyCount=$(echo "${results}" | grep -c -v '^NAME' || true)
  fi
  if (( policyCount == 0 )); then
    if [ "${try}" -eq "${retries}" ]; then
      : "Error: no policies found after ${retries} attempts"
      exit 1
    fi
    : "Try ${try}/${retries}: No policies found yet. Checking again in 30 seconds"
    sleep 30
    continue
  fi
  notready=$(echo "${results}" | grep -E 'NonCompliant|Pending' || true)
  if [ "${notready}" == "" ]; then
    : "OPP policyset is applied and compliant"
    break
  else
    if [ "${try}" -eq "${retries}" ]; then
      if [ "${IGNORE_SECONDARY_POLICIES}" == "true" ]; then
        candidates=$(echo "${notready}" | grep -v policy-acs | grep -v policy-advanced-managed-cluster-status | grep -v policy-hub-quay-bridge | grep -v policy-quay-status || true)
        if [ -z "${candidates}" ]; then
          : "Warning: Proceeding with OPP QE tests with some policy failures"
          exit 0
        else
          : "Error: policies failed to become compliant in allotted time, even considering the ignore list."
          exit 1
        fi
      else
        : "Error: policies failed to become compliant in allotted time."
        exit 1
      fi
    fi
    : "Try ${try}/${retries}: Policies are not compliant. Checking again in 30 seconds"
    sleep 30
  fi
done
