#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Collect all JUnit XMLs from SHARED_DIR into ARTIFACT_DIR
cp "${SHARED_DIR}"/junit-*.xml "${ARTIFACT_DIR}/" 2>/dev/null || true

# Enrich JUnit XMLs with CI properties and generate combined report.
# Environment variables (INFRA_PROVIDER, DEPLOYMENT_ENV, REGION, etc.) are
# already set via capz-test-env.sh. Prow also sets BUILD_ID and JOB_NAME
# automatically, so they will be captured as properties.
./scripts/enrich-junit-xml.sh "${ARTIFACT_DIR}"

# Reuse existing make summary target with ARTIFACT_DIR as the results directory
make summary LATEST_RESULTS_DIR="${ARTIFACT_DIR}"
