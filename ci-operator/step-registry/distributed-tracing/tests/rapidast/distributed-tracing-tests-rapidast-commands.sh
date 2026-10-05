#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${RHOSDT_VERSION:-}" ]]; then
  echo "ERROR: RHOSDT_VERSION is not set. Provide it via steps.env in the job config."
  exit 1
fi

if [[ ! -s "${RAPIDAST_GCS_KEY_FILE}" ]]; then
  echo "ERROR: ${RAPIDAST_GCS_KEY_FILE} is missing or empty."
  echo "Add the rapidast-sa-rhosdt-key key (Google Cloud service account key of the RapiDAST results bucket) to the"
  echo "distributed-tracing/distributed-tracing-team secret collection."
  exit 1
fi

git clone --depth 1 --branch "${DISTRIBUTED_TRACING_QE_BRANCH}" https://github.com/openshift/distributed-tracing-qe.git /tmp/distributed-tracing-tests
cd /tmp/distributed-tracing-tests

# Create the secret manifest that the test applies in the rapidast namespace.
# The namespace has the name of the test directory (rapidast-otel, rapidast-tempo).
kubectl create secret generic rapidast-sa-rhosdt-key \
  --from-file=sa-key="${RAPIDAST_GCS_KEY_FILE}" \
  --namespace="$(basename "${RAPIDAST_TEST_DIR}")" \
  --dry-run=client -o yaml > "${RAPIDAST_TEST_DIR}/gcs-secret.yaml"

# NAMESPACE conflicts with chainsaw.
unset NAMESPACE
export RHOSDT_VERSION

chainsaw test \
  --config .chainsaw-rh-sdl.yaml \
  --report-name "junit_rapidast" \
  --report-path "${ARTIFACT_DIR}" \
  --report-format "XML" \
  --test-dir "${RAPIDAST_TEST_DIR}"
