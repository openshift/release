#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=/var/run/kubeconfig/kubeconfig
job-run-aggregator analyze-job-runs \
  --google-service-account-credential-file=${GOOGLE_SA_CREDENTIAL_FILE} \
  --job=${VERIFICATION_JOB_NAME} \
  --aggregation-id=${AGGREGATION_ID} \
  --explicit-gcs-prefix=${EXPLICIT_GCS_PREFIX} \
  --job-start-time=${JOB_START_TIME} \
  --working-dir=${WORKING_DIR} \
  --timeout=7h \
  --query-source=cluster
