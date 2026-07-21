#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

HYPERFLEET_API_URL=$(cat "${SHARED_DIR}/hyperfleet_api_url")
MAESTRO_URL=$(cat "${SHARED_DIR}/maestro_url")

cp -r /e2e/ /tmp/

# Clone and build from a specific ref if requested (RC/release testing)
E2E_REF="${MULTISTAGE_PARAM_OVERRIDE_E2E_REF:-}"
GINKGO_BIN="ginkgo"
E2E_TEST_BIN="/usr/local/bin/e2e.test"
TESTDATA="/e2e/testdata"
if [ -n "$E2E_REF" ]; then
  log "=== Building E2E from ref: ${E2E_REF} ==="
  git clone --branch "$E2E_REF" --depth 1 \
    https://github.com/openshift-hyperfleet/hyperfleet-e2e.git /tmp/e2e-src
  cd /tmp/e2e-src
  make build
  # Build ginkgo CLI and test binary for parallel execution
  cd .bingo && GOWORK=off go build -mod=mod -modfile=ginkgo.mod \
    -o /tmp/e2e-src/bin/ginkgo "github.com/onsi/ginkgo/v2/ginkgo"
  cd ..
  CGO_ENABLED=0 go test -c -o /tmp/e2e-src/bin/e2e.test ./e2e
  GINKGO_BIN="/tmp/e2e-src/bin/ginkgo"
  E2E_TEST_BIN="/tmp/e2e-src/bin/e2e.test"
  TESTDATA="/tmp/e2e-src/testdata"
  rm -rf /tmp/e2e/env /tmp/e2e/configs
  cp -r /tmp/e2e-src/env /tmp/e2e/env
  cp -r /tmp/e2e-src/configs /tmp/e2e/configs
  cd -
  log "=== E2E build complete ==="
fi

# Change to /tmp/e2e to ensure tests can create .test-work directory
cd /tmp/e2e
source /tmp/e2e/env/env.ci

export HYPERFLEET_API_URL
export MAESTRO_URL
export HYPERFLEET_E2E_CREDENTIALS_PATH="/var/run/hyperfleet-e2e/"
export TESTDATA_DIR="${TESTDATA}"

# Extract namespace from shared dir
NAMESPACE=$(cat "${SHARED_DIR}/namespace_name")
export NAMESPACE

# Extract gcp project id from shared dir
GCP_PROJECT_ID=$(cat "${SHARED_DIR}/gcp_project_id")
export GCP_PROJECT_ID

# Extract run id from shared dir
RUN_ID=$(cat "${SHARED_DIR}/run_id")
export RUN_ID

# Extract kubeconfig from shared dir
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
# Export adapter parameters for the test
export ADAPTER_CHART_REPO="${ADAPTER_CHART_REPO:-https://github.com/openshift-hyperfleet/hyperfleet-adapter.git}"
export ADAPTER_CHART_REF="${ADAPTER_CHART_REF:-main}"
export ADAPTER_CHART_PATH="${ADAPTER_CHART_PATH:-charts}"
export IMAGE_REGISTRY="${IMAGE_REGISTRY:-registry.ci.openshift.org}"
export ADAPTER_IMAGE_REPO="${ADAPTER_IMAGE_REPO:-ci/hyperfleet-adapter}"
export ADAPTER_IMAGE_TAG="${MULTISTAGE_PARAM_OVERRIDE_ADAPTER_IMAGE_TAG:-latest}"

# Export API chart parameters for tier2 tests
export API_CHART_REPO="${API_CHART_REPO:-https://github.com/openshift-hyperfleet/hyperfleet-api.git}"
export API_CHART_REF="${API_CHART_REF:-main}"
export API_CHART_PATH="${API_CHART_PATH:-charts}"

# JWT authentication via K8s TokenRequest API
# The E2E framework acquires a JWT at startup using the SA token
export HYPERFLEET_IDENTITY_TOKENREQUEST_SERVICEACCOUNTNAME="${HYPERFLEET_IDENTITY_TOKENREQUEST_SERVICEACCOUNTNAME:-default}"
export HYPERFLEET_IDENTITY_TOKENREQUEST_NAMESPACE="${NAMESPACE}"
export HYPERFLEET_IDENTITY_EXPECTEDIDENTITY="system:serviceaccount:${NAMESPACE}:${HYPERFLEET_IDENTITY_TOKENREQUEST_SERVICEACCOUNTNAME}"

export GOOGLE_APPLICATION_CREDENTIALS="${HYPERFLEET_E2E_CREDENTIALS_PATH}/hcm-hyperfleet-e2e.json"

# Run e2e tests via ginkgo CLI with parallel execution
"${GINKGO_BIN}" \
  --procs="${PROCS:-4}" \
  --label-filter="${LABEL_FILTER}" \
  --flake-attempts="${FLAKE_ATTEMPTS:-2}" \
  --junit-report=junit.xml \
  --output-dir="${ARTIFACT_DIR}" \
  "${E2E_TEST_BIN}"
