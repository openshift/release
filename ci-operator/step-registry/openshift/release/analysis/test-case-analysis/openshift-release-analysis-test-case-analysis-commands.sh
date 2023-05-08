#!/bin/bash

set -o nounset
set +o errexit
set -o pipefail

DEFAULT_MINIMUM_SUCCESSFUL_COUNT=1
TEST_GROUP=install
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
  job-run-aggregator analyze-test-case \
    --google-service-account-credential-file "${GOOGLE_SA_CREDENTIAL_FILE}" \
    --payload-tag="${PAYLOAD_TAG}" \
    --minimum-successful-count="${min_successful}" \
    --job-start-time="${JOB_START_TIME}" \
    --working-dir="${artifacts}" \
    --timeout=4h30m \
    $parameters \
    --test-group="${TEST_GROUP}" > "${artifacts}/${analysis}.log" 2>&1  &
  PIDS="$PIDS $!"
  echo "PID is $!"
}

run_analysis aws-ovn-ipi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=aws \
  --network=ovn \
  --infrastructure=ipi

run_analysis aws-sdn-ipi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=aws \
  --network=sdn \
  --infrastructure=ipi

run_analysis azure-ovn-ipi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=azure \
  --network=ovn \
  --infrastructure=ipi

run_analysis gcp-sdn-ipi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=gcp \
  --network=sdn \
  --infrastructure=ipi

run_analysis vsphere-ovn-ipi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=vsphere \
  --network=ovn \
  --infrastructure=ipi

run_analysis vsphere-sdn-ipi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=vsphere \
  --network=sdn \
  --infrastructure=ipi \

run_analysis vsphere-ovn-upi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=vsphere \
  --network=ovn \
  --infrastructure=upi

run_analysis metal-ovn-ipi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=metal \
  --network=ovn \
  --infrastructure=ipi

run_analysis metal-sdn-ipi $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --platform=metal \
  --network=sdn \
  --infrastructure=ipi

run_analysis aws-proxy $DEFAULT_MINIMUM_SUCCESSFUL_COUNT \
  --include-job-names=ovn-proxy

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
