#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM


log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

source ./tests/prow_ci.sh
extract_existing_junit $SHARED_DIR

log "INFO: Generate report portal report ..."
rosatest --ginkgo.v --ginkgo.no-color --ginkgo.timeout "10m" --ginkgo.label-filter "e2e-report"
log "\nTest results:"
cat "$ARTIFACT_DIR/e2e-test-results.json"
# Remove the old junit.xml file
rm -rf ${SHARED_DIR}/*.xml

failures=$(cat $ARTIFACT_DIR/e2e-test-results.json | jq -r '.failures')
if [[ $failures -gt 0 ]]; then
  log "Error: Execute testing failed. Detail logs are under $ARTIFACT_DIR/junit"
  exit 1
fi
