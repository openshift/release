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

# Use ref-specific binary and resources if available (built by setup step)
E2E_REF="${MULTISTAGE_PARAM_OVERRIDE_E2E_REF:-}"
E2E_BIN="hyperfleet-e2e"
TESTDATA="/e2e/testdata"
if [ -n "$E2E_REF" ]; then
  for required in hyperfleet-e2e testdata deploy-scripts configs; do
    if [ ! -e "${SHARED_DIR}/${required}" ]; then
      log "ERROR: E2E_REF=${E2E_REF} but ${SHARED_DIR}/${required} missing — setup step regressed"
      exit 1
    fi
  done
  E2E_BIN="${SHARED_DIR}/hyperfleet-e2e"
  chmod +x "$E2E_BIN"
  TESTDATA="${SHARED_DIR}/testdata"
  rm -rf /tmp/e2e/deploy-scripts /tmp/e2e/configs
  cp -r "${SHARED_DIR}/deploy-scripts" /tmp/e2e/deploy-scripts
  cp -r "${SHARED_DIR}/configs" /tmp/e2e/configs
  log "Using E2E artifacts from ref: ${E2E_REF}"
fi

cd "/tmp/e2e/deploy-scripts/"
cp  .env.example .env
source .env

export HYPERFLEET_API_URL
export MAESTRO_URL
export HYPERFLEET_E2E_CREDENTIALS_PATH="/var/run/hyperfleet-e2e/"
export TESTDATA_DIR="${TESTDATA}"
NAMESPACE=$(cat "${SHARED_DIR}/namespace_name")
export NAMESPACE

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

# Run e2e tests via --label-filter
"${E2E_BIN}" test --label-filter="${LABEL_FILTER}" --junit-report "${ARTIFACT_DIR}/junit.xml"
