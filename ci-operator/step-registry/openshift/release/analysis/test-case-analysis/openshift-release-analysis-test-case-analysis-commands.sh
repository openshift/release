#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

job-run-aggregator analyze-test-case \
  --google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
  --payload-tag=${PAYLOAD_TAG} \
  --platform=${PLATFORM} \
  --network=${NETWORK} \
  --infrastructure=${INFRASTRUCTURE} \
  --minimum-successful-count=${MINIMUM_SUCCESSFUL_COUNT} \
  --job-start-time=${JOB_START_TIME} \
  --working-dir=${WORKING_DIR} \
  --timeout=4h30m \
  --test-group=${TEST_GROUP}
