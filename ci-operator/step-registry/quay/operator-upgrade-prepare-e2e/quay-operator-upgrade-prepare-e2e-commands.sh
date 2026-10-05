#!/bin/bash
set -euo pipefail

NAMESPACE="${QUAY_UPGRADE_QUAY_NAMESPACE:-quay}"
REGISTRY="${QUAY_UPGRADE_QUAY_REGISTRY:-quay}"
TIMEOUT="${QUAY_UPGRADE_READINESS_TIMEOUT:-15m}"
REQUIRED_SAMPLES="${QUAY_UPGRADE_ROUTE_READY_SAMPLES:-5}"
PROBE_INTERVAL_SECONDS="${QUAY_UPGRADE_ROUTE_PROBE_INTERVAL_SECONDS:-5}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
READINESS_LOG="${ARTIFACT_DIR}/route-readiness.jsonl"

[[ "${TIMEOUT}" =~ ^([1-9][0-9]*)([smh])$ ]] || { echo "ERROR: QUAY_UPGRADE_READINESS_TIMEOUT must be a positive Ns, Nm, or Nh duration" >&2; exit 1; }
case "${BASH_REMATCH[2]}" in s) seconds="${BASH_REMATCH[1]}";; m) seconds="$((BASH_REMATCH[1] * 60))";; h) seconds="$((BASH_REMATCH[1] * 3600))";; esac
[[ "${REQUIRED_SAMPLES}" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: QUAY_UPGRADE_ROUTE_READY_SAMPLES must be a positive integer" >&2; exit 1; }
[[ "${PROBE_INTERVAL_SECONDS}" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: QUAY_UPGRADE_ROUTE_PROBE_INTERVAL_SECONDS must be a positive integer" >&2; exit 1; }

deadline=$(( $(date +%s) + seconds ))

# Prefer the build-support passthrough cert when present; otherwise the cluster
# default ingress CA. Fall back to curl -k only if neither is available.
ROUTER_CA="$(mktemp)"
cleanup() { rm -f "${ROUTER_CA}"; }
trap cleanup EXIT
if [[ -s "${SHARED_DIR}/ssl.cert" ]]; then
  cp "${SHARED_DIR}/ssl.cert" "${ROUTER_CA}"
elif oc -n openshift-config-managed get configmap default-ingress-cert -o jsonpath='{.data.ca-bundle\.crt}' >"${ROUTER_CA}" 2>/dev/null \
  && [[ -s "${ROUTER_CA}" ]]; then
  :
else
  : >"${ROUTER_CA}"
fi

curl_probe() {
  local url="$1" body="$2"
  local curl_args=(-sS -m 10 -o "${body}" -w '%{http_code}')
  if [[ -s "${ROUTER_CA}" ]]; then
    curl_args+=(--cacert "${ROUTER_CA}")
  else
    curl_args+=(-k)
  fi
  LC_ALL=C curl "${curl_args[@]}" "${url}" 2>/dev/null || true
}

# Quay's documented readiness signal is /health/instance (HTTP 200 + services up).
# Also try /status in case a deployment exposes it; prefer whichever first returns
# HTTP 200 and stick with that path for the consecutive-sample streak.
select_probe_path() {
  local endpoint="$1"
  local path http_code body
  for path in /status /health/instance /health /api/v1/discovery; do
    body="$(mktemp)"
    http_code="$(curl_probe "${endpoint}${path}" "${body}")"
    echo "  probe candidate ${endpoint}${path} -> HTTP ${http_code:-000}" >&2
    if [[ "${http_code}" == "200" ]]; then
      # /status is not a documented Quay health API; accept it only when the body
      # looks like JSON status (contains status_code) rather than an HTML/SPA shell.
      if [[ "${path}" == "/status" ]]; then
        if grep -q 'status_code\|"services"' "${body}" 2>/dev/null; then
          rm -f "${body}"
          printf '%s\n' "${path}"
          return 0
        fi
        echo "  /status returned 200 but body is not a Quay status/health document; skipping" >&2
        rm -f "${body}"
        continue
      fi
      rm -f "${body}"
      printf '%s\n' "${path}"
      return 0
    fi
    rm -f "${body}"
  done
  return 1
}

quay_app_ready() {
  local deployment desired ready_replicas found=false
  # quay-component=quay labels the app Deployment metadata; quay-app is only the
  # pod-template/selector label (see quay-operator-upgrade-channel).
  while IFS= read -r deployment; do
    [[ -n "${deployment}" ]] || continue
    found=true
    desired="$(oc get deployment -n "${NAMESPACE}" "${deployment}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    ready_replicas="$(oc get deployment -n "${NAMESPACE}" "${deployment}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    [[ -n "${desired}" && "${desired}" == "${ready_replicas:-0}" ]] || return 1
  done < <(oc get deployment -n "${NAMESPACE}" -l quay-component=quay -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  [[ "${found}" == true ]]
}

echo "Waiting for QuayRegistry ${NAMESPACE}/${REGISTRY} Available + registry endpoint (timeout ${TIMEOUT})..."
endpoint=""
while (( $(date +%s) < deadline )); do
  available="$(oc get quayregistry -n "${NAMESPACE}" "${REGISTRY}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  endpoint="$(oc get quayregistry -n "${NAMESPACE}" "${REGISTRY}" -o jsonpath='{.status.registryEndpoint}' 2>/dev/null || true)"
  if [[ "${available}" == True && "${endpoint}" =~ ^https?:// ]]; then
    echo "QuayRegistry is Available at ${endpoint}"
    break
  fi
  sleep 10
done
if [[ "${available:-}" != True || ! "${endpoint:-}" =~ ^https?:// ]]; then
  echo "ERROR: QuayRegistry ${NAMESPACE}/${REGISTRY} did not become Available with an HTTP(S) endpoint within ${TIMEOUT}" >&2
  oc get quayregistry -n "${NAMESPACE}" "${REGISTRY}" -o yaml >"${ARTIFACT_DIR}/quayregistry.yaml" 2>/dev/null || true
  exit 1
fi

printf '%s\n' "${endpoint}" >"${SHARED_DIR}/quayroute"

echo "Waiting for quay-app Deployment readyReplicas..."
while (( $(date +%s) < deadline )); do
  if quay_app_ready; then
    echo "quay-app Deployment replicas are ready"
    break
  fi
  sleep 10
done
if ! quay_app_ready; then
  echo "ERROR: quay-app Deployment did not become ready within ${TIMEOUT}" >&2
  oc get deployment -n "${NAMESPACE}" -l quay-component=quay -o wide >"${ARTIFACT_DIR}/quay-app-deployments.txt" 2>/dev/null || true
  oc get pods -n "${NAMESPACE}" -o wide >"${ARTIFACT_DIR}/quay-pods.txt" 2>/dev/null || true
  exit 1
fi

echo "Selecting a working route probe path on ${endpoint} (trying /status, then documented /health/instance)..."
probe_path=""
while (( $(date +%s) < deadline )); do
  if probe_path="$(select_probe_path "${endpoint}")"; then
    echo "Using route probe path: ${probe_path}"
    break
  fi
  sleep "${PROBE_INTERVAL_SECONDS}"
done
if [[ -z "${probe_path}" ]]; then
  echo "ERROR: no route probe path on ${endpoint} returned HTTP 200 within ${TIMEOUT} (tried /status, /health/instance, /health, /api/v1/discovery)" >&2
  exit 1
fi

probe_url="${endpoint}${probe_path}"
echo "Waiting for ${REQUIRED_SAMPLES} consecutive healthy samples from ${probe_url}..."
: >"${READINESS_LOG}"
consecutive=0
attempt=0
body="$(mktemp)"
while (( $(date +%s) < deadline )); do
  attempt=$((attempt + 1))
  http_code="$(curl_probe "${probe_url}" "${body}")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"timestamp":"%s","attempt":%d,"url":"%s","http_status":"%s"}\n' \
    "${ts}" "${attempt}" "${probe_url}" "${http_code:-000}" >>"${READINESS_LOG}"

  if [[ "${http_code}" == "200" ]]; then
    consecutive=$((consecutive + 1))
    echo "  route ready ${consecutive}/${REQUIRED_SAMPLES} (attempt ${attempt}, HTTP 200 ${probe_path})"
    if [[ "${consecutive}" -ge "${REQUIRED_SAMPLES}" ]]; then
      rm -f "${body}"
      echo "QuayRegistry ${NAMESPACE}/${REGISTRY} is Available and accepting traffic at ${endpoint} (${probe_path}); wrote SHARED_DIR/quayroute."
      exit 0
    fi
  else
    echo "  route not ready (attempt ${attempt}, HTTP ${http_code:-000} ${probe_path})"
    consecutive=0
  fi
  sleep "${PROBE_INTERVAL_SECONDS}"
done

rm -f "${body}"
echo "ERROR: Quay route ${probe_url} did not return ${REQUIRED_SAMPLES} consecutive HTTP 200 responses within ${TIMEOUT}" >&2
oc get quayregistry -n "${NAMESPACE}" "${REGISTRY}" -o yaml >"${ARTIFACT_DIR}/quayregistry.yaml" 2>/dev/null || true
oc get pods -n "${NAMESPACE}" -o wide >"${ARTIFACT_DIR}/quay-pods.txt" 2>/dev/null || true
oc get route -n "${NAMESPACE}" -o wide >"${ARTIFACT_DIR}/quay-routes.txt" 2>/dev/null || true
exit 1
