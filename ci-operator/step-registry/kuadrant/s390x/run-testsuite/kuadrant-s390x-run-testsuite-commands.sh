#!/bin/bash

set -euo pipefail

# This step runs on the amd64 build-farm (not on the s390x cluster). The cluster
# under test is s390x; workloads that land on that cluster still use s390x images
# (httpbin/mockserver/etc.). The runner itself uses quay.io/kuadrant/testsuite
# which already provides Python 3.11, Poetry, make, git and CFSSL.

TESTSUITE_DIR="${TESTSUITE_DIR}"
RESULTS_DIR="${ARTIFACT_DIR}/test-run-results"
mkdir -p "${RESULTS_DIR}"

# OpenShift CI injects the cluster kubeconfig; prefer that over the image default.
if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

KEYCLOAK_URL="$(cat "${SHARED_DIR}/keycloak-url")"
MOCKSERVER_URL="$(cat "${SHARED_DIR}/mockserver-url")"
JAEGER_QUERY_URL="$(cat "${SHARED_DIR}/jaeger-query-url")"
JAEGER_COLLECTOR_URL="rpc://jaeger-collector.${TOOLS_NAMESPACE}.svc.cluster.local:4317"

CFSSL_BIN="$(command -v cfssl || true)"
if [[ -z "${CFSSL_BIN}" ]]; then
  echo "ERROR: cfssl not found in the kuadrant-testsuite image" >&2
  exit 1
fi

if ! command -v poetry >/dev/null 2>&1; then
  echo "ERROR: poetry not found in the kuadrant-testsuite image" >&2
  exit 1
fi

if ! command -v make >/dev/null 2>&1; then
  echo "ERROR: make not found in the kuadrant-testsuite image" >&2
  exit 1
fi

echo "=== Cloning Kuadrant testsuite (${TESTSUITE_GITREF}) ==="
rm -rf "${TESTSUITE_DIR}"
git clone --depth 1 --branch "${TESTSUITE_GITREF}" "${TESTSUITE_REPO}" "${TESTSUITE_DIR}"
cd "${TESTSUITE_DIR}"

echo "=== Syncing Poetry dependencies (no dev, no Playwright) ==="
export POETRY_VIRTUALENVS_IN_PROJECT=true
make poetry-no-dev

echo "=== Generating config/settings.local.yaml ==="
mkdir -p config
# Disable tracing while writing credentials into the config file
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
cat > config/settings.local.yaml <<EOF
default:
  cfssl: "${CFSSL_BIN}"
  service_protection:
    system_project: "${KUADRANT_NAMESPACE}"
    project: "kuadrant"
    project2: "kuadrant2"
    authorino:
      deploy: false
  default_exposer: "openshift"
  control_plane:
    cluster: {}
    provider_secret: "${DNS_PROVIDER_SECRET_NAME}"
    issuer:
      name: "${CLUSTER_ISSUER_NAME}"
      kind: "ClusterIssuer"
  tools:
    project: "${TOOLS_NAMESPACE}"
  keycloak:
    url: "${KEYCLOAK_URL}"
    username: "${KEYCLOAK_ADMIN_USERNAME}"
    password: "${KEYCLOAK_ADMIN_PASSWORD}"
    test_user:
      username: "testUser"
      password: "testPassword"
  httpbin:
    image: "${HTTPBIN_IMAGE}"
  tracing:
    backend: "jaeger"
    collector_url: "${JAEGER_COLLECTOR_URL}"
    query_url: "${JAEGER_QUERY_URL}"
  mockserver:
    url: "${MOCKSERVER_URL}"
    image: "${MOCKSERVER_IMAGE}"
  llm_sim:
    image: "${LLM_SIM_IMAGE}"
  spicedb:
    image: "${SPICEDB_IMAGE}"
EOF
$WAS_TRACING && set -x

echo "Generated config/settings.local.yaml (credentials redacted in logs)."

export junit=yes
export resultsdir="${RESULTS_DIR}"
export USER="${USER:-ci}"

FAILED=0

if [[ "${RUN_SMOKE}" == "true" ]]; then
  echo "=== Running smoke tests (no Playwright) ==="
  if ! flags="${PYTEST_FLAGS}" make smoke; then
    echo "WARNING: smoke tests reported failures" >&2
    FAILED=1
  fi
fi

if [[ "${RUN_KUADRANT}" == "true" ]]; then
  echo "=== Running single-cluster Kuadrant tests (make kuadrant, no ui/playwright) ==="
  if ! flags="${PYTEST_FLAGS}" make kuadrant; then
    echo "ERROR: kuadrant tests reported failures" >&2
    FAILED=1
  fi
fi

echo "=== Polishing JUnit reports ==="
make polish-junit || true

echo "=== Copying test artifacts to ${ARTIFACT_DIR} ==="
cp -a "${RESULTS_DIR}/." "${ARTIFACT_DIR}/" || true
if ls "${RESULTS_DIR}"/junit-*.xml >/dev/null 2>&1; then
  cp "${RESULTS_DIR}"/junit-*.xml "${ARTIFACT_DIR}/"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "Testsuite finished with failures." >&2
  exit 1
fi

echo "=== Kuadrant testsuite run complete ==="
