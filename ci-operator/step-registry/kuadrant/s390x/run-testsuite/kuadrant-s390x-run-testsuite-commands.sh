#!/bin/bash

set -euo pipefail

# This step runs on the amd64 build-farm (not on the s390x cluster). The runner
# image is based on quay.io/kuadrant/testsuite, which already COPYs the testsuite
# sources and runs `make poetry-no-dev` at build time
# (https://github.com/Kuadrant/testsuite/blob/main/Dockerfile).
#
# Stay in the baked-in WORKDIR so Poetry reuses the image virtualenv
# (POETRY_VIRTUALENVS_PATH=/opt/workdir/virtualenvs). OpenShift CI runs as an
# arbitrary UID that cannot write that path or the image WORKDIR, so:
#   - dynaconf overrides go to SECRETS_FOR_DYNACONF on a writable file
#     (same pattern as mounting settings → /run/secrets.yaml in the README)
#   - PYTHONPYCACHEPREFIX keeps .pyc writes out of the read-only tree
# Workload images on the s390x cluster remain s390x-specific.

TESTSUITE_DIR="${TESTSUITE_DIR}"
RESULTS_DIR="${ARTIFACT_DIR}/test-run-results"
mkdir -p "${RESULTS_DIR}"
mkdir -p "${HOME}/.pycache"
export PYTHONPYCACHEPREFIX="${HOME}/.pycache"

# OpenShift CI injects the cluster kubeconfig; prefer that over the image default
# (/run/kubeconfig from the Dockerfile).
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

if [[ ! -d "${TESTSUITE_DIR}" ]]; then
  echo "ERROR: baked-in testsuite directory not found at ${TESTSUITE_DIR}" >&2
  exit 1
fi

cd "${TESTSUITE_DIR}"
echo "=== Using baked-in Kuadrant testsuite at ${TESTSUITE_DIR} ==="

# Dynaconf secrets file (writable). Matches the container usage documented in
# Kuadrant/testsuite README: mount settings as SECRETS_FOR_DYNACONF=/run/secrets.yaml
export SECRETS_FOR_DYNACONF="${SHARED_DIR}/kuadrant-secrets.yaml"
echo "=== Generating ${SECRETS_FOR_DYNACONF} ==="
# Disable tracing while writing credentials into the config file
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
cat > "${SECRETS_FOR_DYNACONF}" <<EOF
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

echo "Generated dynaconf secrets file (credentials redacted in logs)."

# ci-operator overrides the image ENTRYPOINT; invoke make targets explicitly.
export junit=yes
export resultsdir="${RESULTS_DIR}"
export USER="${USER:-ci}"

PROXY_LOG_DIR="${ARTIFACT_DIR}/gateway-istio-proxy-logs"
PROXY_COLLECTOR_PID=""

# Gateway/istio-proxy pods are created and deleted by the testsuite during smoke.
# A post-smoke dump is too late; follow istio-proxy logs concurrently into
# ARTIFACT_DIR while make smoke runs so wasm load errors survive teardown.
start_istio_proxy_log_collector() {
  mkdir -p "${PROXY_LOG_DIR}/.seen" "${PROXY_LOG_DIR}/.pids"
  echo "=== Starting concurrent istio-proxy log collector → ${PROXY_LOG_DIR} ==="
  (
    while true; do
      oc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null \
        | while IFS=$'\t' read -r ns name containers; do
            [[ -n "${ns}" && -n "${name}" ]] || continue
            [[ " ${containers} " == *" istio-proxy "* || "${containers}" == *istio-proxy* ]] || continue
            # Focus on Istio Gateway dataplane pods (…-istio-…); skip istiod/etc.
            [[ "${name}" == *"-istio-"* || "${name}" == *"-istio" ]] || continue
            key="${ns}_${name}"
            seen_file="${PROXY_LOG_DIR}/.seen/${key}"
            [[ -e "${seen_file}" ]] && continue
            : >"${seen_file}"
            out="${PROXY_LOG_DIR}/${ns}_${name}_istio-proxy.log"
            echo "[collector] following ${ns}/${name} -c istio-proxy → ${out}"
            (
              # Stream until the pod disappears; retry briefly while it is Starting.
              while oc get pod -n "${ns}" "${name}" >/dev/null 2>&1; do
                oc logs -n "${ns}" "${name}" -c istio-proxy -f --timestamps=true >>"${out}" 2>&1 && break
                sleep 2
              done
            ) &
            echo $! >"${PROXY_LOG_DIR}/.pids/${key}.pid"
          done
      sleep 3
    done
  ) &
  PROXY_COLLECTOR_PID=$!
  echo "${PROXY_COLLECTOR_PID}" >"${PROXY_LOG_DIR}/.collector.pid"
}

stop_istio_proxy_log_collector() {
  echo "=== Stopping concurrent istio-proxy log collector ==="
  if [[ -n "${PROXY_COLLECTOR_PID}" ]] && kill -0 "${PROXY_COLLECTOR_PID}" 2>/dev/null; then
    pkill -P "${PROXY_COLLECTOR_PID}" 2>/dev/null || true
    kill "${PROXY_COLLECTOR_PID}" 2>/dev/null || true
  elif [[ -f "${PROXY_LOG_DIR}/.collector.pid" ]]; then
    local pid
    pid="$(cat "${PROXY_LOG_DIR}/.collector.pid" 2>/dev/null || true)"
    if [[ -n "${pid}" ]]; then
      pkill -P "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
    fi
  fi
  if [[ -d "${PROXY_LOG_DIR}/.pids" ]]; then
    local f
    for f in "${PROXY_LOG_DIR}/.pids"/*.pid; do
      [[ -f "${f}" ]] || continue
      kill "$(cat "${f}")" 2>/dev/null || true
    done
  fi
  sleep 1
  wait 2>/dev/null || true

  echo "--- captured istio-proxy log files ---"
  ls -la "${PROXY_LOG_DIR}"/*_istio-proxy.log 2>/dev/null || echo "(no proxy log files captured)"
  {
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) istio-proxy wasm/error summary ====="
    if ls "${PROXY_LOG_DIR}"/*_istio-proxy.log >/dev/null 2>&1; then
      grep -h -iE 'wasm|plugin\.wasm|Unable to create|error|fail|503|ratelimit' \
        "${PROXY_LOG_DIR}"/*_istio-proxy.log 2>/dev/null || echo "(no wasm/error matches in captured logs)"
    else
      echo "(no proxy log files captured)"
    fi
  } | tee "${ARTIFACT_DIR}/gateway-istio-proxy-wasm-summary.txt" || true
}

dump_s390x_smoke_diagnostics() {
  local out="${ARTIFACT_DIR}/kuadrant-smoke-diagnostics.txt"
  echo "=== Dumping post-smoke diagnostics to ${out} ==="
  {
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) smoke diagnostics ====="
    echo "--- Kuadrant CRs ---"
    oc get kuadrant -A -o wide 2>&1 || true
    oc get kuadrant -A -o yaml 2>&1 || true

    echo "--- operator RELATED_IMAGE_WASMSHIM ---"
    oc set env deployment/kuadrant-operator-controller-manager \
      -n "${KUADRANT_NAMESPACE}" --list 2>&1 | grep RELATED_IMAGE || true

    echo "--- kuadrant-operator-wasm Service / Endpoints ---"
    oc get svc,endpoints kuadrant-operator-wasm -n "${KUADRANT_NAMESPACE}" -o wide 2>&1 || true
    oc get svc,endpoints kuadrant-operator-wasm -n "${KUADRANT_NAMESPACE}" -o yaml 2>&1 || true

    echo "--- WasmPlugin (all namespaces) ---"
    oc get wasmplugin -A -o wide 2>&1 || true
    oc get wasmplugin -A -o yaml 2>&1 || true

    echo "--- RateLimitPolicy / AuthPolicy ---"
    oc get ratelimitpolicy -A -o wide 2>&1 || true
    oc get ratelimitpolicy -A -o yaml 2>&1 || true
    oc get authpolicy -A -o wide 2>&1 || true

    echo "--- Gateways / HTTPRoutes ---"
    oc get gateway -A -o wide 2>&1 || true
    oc get httproute -A -o wide 2>&1 || true

    echo "--- Limitador / Authorino ---"
    oc get limitador -A -o wide 2>&1 || true
    oc get limitador -A -o yaml 2>&1 || true
    oc get pods -A -l 'app.kubernetes.io/name=limitador' -o wide 2>&1 || true
    oc get pods -A -l 'app.kubernetes.io/name=authorino' -o wide 2>&1 || true

    echo "--- kuadrant-operator recent logs (wasm/shim/error) ---"
    oc logs -n "${KUADRANT_NAMESPACE}" deploy/kuadrant-operator-controller-manager \
      --tail=200 2>&1 | grep -iE 'wasm|shim|error|fail|ratelimit' || true

    echo "--- istiod / remaining gateway proxy log snippets (wasm) ---"
    for ns in istio-system openshift-operators "${KUADRANT_NAMESPACE}" kuadrant kuadrant2; do
      for pod in $(oc get pods -n "${ns}" -o name 2>/dev/null | grep -E 'istiod|gateway|istio-ingress|-istio-' || true); do
        echo ">>> ${ns}/${pod}"
        oc logs -n "${ns}" "${pod}" -c discovery --tail=80 2>/dev/null | grep -iE 'wasm|error|fail' || true
        oc logs -n "${ns}" "${pod}" -c istio-proxy --tail=80 2>/dev/null | grep -iE 'wasm|error|fail|503' || true
        oc logs -n "${ns}" "${pod}" --all-containers --tail=40 2>/dev/null | grep -iE 'wasm|error|fail' || true
      done
    done
    # Also scan any leftover kuadrant* namespaces still present
    for ns in $(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^kuadrant' || true); do
      for pod in $(oc get pods -n "${ns}" -o name 2>/dev/null | grep -E '-istio-' || true); do
        echo ">>> ${ns}/${pod}"
        oc logs -n "${ns}" "${pod}" -c istio-proxy --tail=200 2>/dev/null || true
      done
    done

    echo "--- DNSPolicy / TLSPolicy (expect DNS issues without real credentials) ---"
    oc get dnspolicy -A -o wide 2>&1 || true
    oc get tlspolicy -A -o wide 2>&1 || true

    echo "--- concurrent istio-proxy captures (see also ${PROXY_LOG_DIR}) ---"
    ls -la "${PROXY_LOG_DIR}"/*_istio-proxy.log 2>/dev/null || echo "(none)"
  } >"${out}" 2>&1 || true
  # Also echo a short summary to the step log
  echo "--- diagnostic summary ---"
  grep -E '^(--- |NAME |Error|error|wasm|RELATED|phase=|message:|Unable)' "${out}" 2>/dev/null | head -80 || true
  echo "(full dump: ${out})"
  echo "(proxy streams: ${PROXY_LOG_DIR}/ ; wasm summary: ${ARTIFACT_DIR}/gateway-istio-proxy-wasm-summary.txt)"
}

FAILED=0

if [[ "${RUN_SMOKE}" == "true" ]]; then
  echo "=== Running smoke tests (no Playwright) ==="
  start_istio_proxy_log_collector
  if ! flags="${PYTEST_FLAGS}" make smoke; then
    echo "WARNING: smoke tests reported failures" >&2
    FAILED=1
  fi
  stop_istio_proxy_log_collector
  dump_s390x_smoke_diagnostics
fi

# Temporarily disable the full single-cluster suite while stabilizing smoke on s390x.
# if [[ "${RUN_KUADRANT}" == "true" ]]; then
#   echo "=== Running single-cluster Kuadrant tests (make kuadrant, no ui/playwright) ==="
#   if ! flags="${PYTEST_FLAGS}" make kuadrant; then
#     echo "ERROR: kuadrant tests reported failures" >&2
#     FAILED=1
#   fi
# fi
echo "=== Skipping make kuadrant (disabled while stabilizing smoke) ==="

# Temporarily skip while stabilizing smoke on s390x.
# echo "=== Polishing JUnit reports ==="
# make polish-junit || true
echo "=== Skipping make polish-junit (disabled while stabilizing smoke) ==="

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
