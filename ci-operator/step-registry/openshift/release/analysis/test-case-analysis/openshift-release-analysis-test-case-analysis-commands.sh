#!/bin/bash

set -o nounset
set +o errexit
set -o pipefail

PIDS=""

function run_analysis() {
  analysis=$1
  min_successful=$2
  parameters=${*:3}
  artifacts="${ARTIFACT_DIR}/$analysis"
  mkdir -p "$artifacts"

  echo
  echo "********** Starting testcase analysis for: ${analysis} "
  echo
  set -x
  export KUBECONFIG=/var/run/kubeconfig/kubeconfig
  job-run-aggregator analyze-test-case \
    --google-service-account-credential-file "${GOOGLE_SA_CREDENTIAL_FILE}" \
    --payload-tag="${PAYLOAD_TAG}" \
    --minimum-successful-count="${min_successful}" \
    --job-start-time="${JOB_START_TIME}" \
    --working-dir="${artifacts}" \
    --timeout=4h30m \
    --query-source=cluster \
    $parameters \
    --test-group="${TEST_GROUP}" > "${artifacts}/${analysis}.log" 2>&1  &
  set +x
  PIDS="$PIDS $!"
  echo "PID is $!"
}

# Read the configuration from the JOB_CONFIGURATION environment
# variable. The variable is a list of configurations separated by
# newline. Each individual configuration is in the format:
#   NAME,MINIMUM_COUNT,PARAMETERS
#
# Example:
#   aws-ovn-ipi,1,--platform=aws --network=ovn --infrastructure=ipi

# Save original Internal Field Separator (IFS)
OIFS="$IFS"

# Iterate over each line in JOB_CONFIGURATION
while IFS=',' read -r name min_count args
do
  # If JOB_CONFIGURATION has a trailing newline, it'll end up with an
  # empty entry and we need to skip it.
  if [[ -z $name || -z $min_count ]];
  then
    continue
  fi

  # Split 'args' into an array
  IFS=' ' read -r -a args_array <<< "$args"

  run_analysis "$name" "$min_count" "${args_array[@]}"

done <<< "$JOB_CONFIGURATION"

# Restore original IFS
IFS="$OIFS"

echo "Waiting for pids to complete: $PIDS"
ret=0
saved_ret=0
for pid in $PIDS
do
  echo "[$(date)] waiting for $pid"
  wait "$pid"
  ret=$?
  if [ $ret -gt 0 ]; then
    echo "[$(date)] $pid finished with ret=$ret"
    saved_ret=$ret
  else
    echo "[$(date)] $pid finished successfully"
  fi
done

echo "Exiting with ret=${saved_ret}"
exit "${saved_ret}"
