#!/bin/bash

set -euo pipefail

TESTSUITE_DIR="${TESTSUITE_DIR}"
RESULTS_DIR="${ARTIFACT_DIR}/test-run-results"
mkdir -p "${RESULTS_DIR}"

KEYCLOAK_URL="$(cat "${SHARED_DIR}/keycloak-url")"
MOCKSERVER_URL="$(cat "${SHARED_DIR}/mockserver-url")"
JAEGER_QUERY_URL="$(cat "${SHARED_DIR}/jaeger-query-url")"
JAEGER_COLLECTOR_URL="rpc://jaeger-collector.${TOOLS_NAMESPACE}.svc.cluster.local:4317"

echo "=== Installing testsuite prerequisites (Python, Poetry, CFSSL) ==="
if ! command -v python3.11 >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y python3.11 python3.11-pip git make curl
    dnf clean all
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-pip git make curl
    dnf clean all || true
  fi
fi

PYTHON="$(command -v python3.11 || command -v python3)"
if ! command -v poetry >/dev/null 2>&1; then
  "${PYTHON}" -m pip install --no-cache-dir poetry
fi

CFSSL_BIN="/usr/local/bin/cfssl"
if ! command -v cfssl >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "${ARCH}" in
    s390x) CFSSL_ARCH="s390x" ;;
    aarch64|arm64) CFSSL_ARCH="arm64" ;;
    *) CFSSL_ARCH="amd64" ;;
  esac
  curl -fsSL "https://github.com/cloudflare/cfssl/releases/download/v1.6.4/cfssl_1.6.4_linux_${CFSSL_ARCH}" -o "${CFSSL_BIN}"
  chmod +x "${CFSSL_BIN}"
fi

echo "=== Cloning Kuadrant testsuite (${TESTSUITE_GITREF}) ==="
rm -rf "${TESTSUITE_DIR}"
git clone --depth 1 --branch "${TESTSUITE_GITREF}" "${TESTSUITE_REPO}" "${TESTSUITE_DIR}"
cd "${TESTSUITE_DIR}"

echo "=== Installing Poetry dependencies (no dev, no Playwright) ==="
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
