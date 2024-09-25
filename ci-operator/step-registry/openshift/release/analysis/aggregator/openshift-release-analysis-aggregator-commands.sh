#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=/var/run/kubeconfig/kubeconfig
job-run-aggregator analyze-job-runs \
  --google-service-account-credential-file ${GOOGLE_SA_CREDENTIAL_FILE} \
  --job=${VERIFICATION_JOB_NAME} \
  --payload-tag=${PAYLOAD_TAG} \
  --job-start-time=${JOB_START_TIME} \
  --working-dir=${WORKING_DIR} \
  --timeout=7h \
  --query-source=cluster
