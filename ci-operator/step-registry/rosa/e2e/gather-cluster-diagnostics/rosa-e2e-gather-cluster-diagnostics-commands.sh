#!/bin/bash
set -o nounset
set -o pipefail
# Do NOT set -o errexit: this script must always exit 0 (best_effort).

DIAG_DIR="${ARTIFACT_DIR}/cluster-diagnostics"
mkdir -p "${DIAG_DIR}"

# ---- helpers ----------------------------------------------------------------

log() {
  echo "[gather-diagnostics] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Always exit 0 so the step never blocks job completion.
cleanup() {
  log "Diagnostics collection complete. Output: ${DIAG_DIR}/"
  ls -lhR "${DIAG_DIR}" 2>/dev/null || true
  exit 0
}
trap cleanup EXIT

# ---- resolve cluster ID -----------------------------------------------------

CLUSTER_ID=""
for candidate in "${SHARED_DIR}/cluster-id" "${SHARED_DIR}/ocm-fvt-cluster-ids"; do
  if [[ -f "${candidate}" ]]; then
    CLUSTER_ID="$(head -1 "${candidate}" | tr -d '[:space:]')"
    if [[ -n "${CLUSTER_ID}" ]]; then
      log "Found cluster ID '${CLUSTER_ID}' from ${candidate}"
      break
    fi
  fi
done

if [[ -z "${CLUSTER_ID}" ]]; then
  log "WARNING: No cluster ID found in SHARED_DIR. Skipping diagnostics."
  log "Expected: \${SHARED_DIR}/cluster-id or \${SHARED_DIR}/ocm-fvt-cluster-ids"
  exit 0
fi

# ---- install OCM CLI tools --------------------------------------------------

ocm_ver="${GATHER_OCM_CLI_VERSION:-1.0.15}"
bp_ver="${GATHER_BACKPLANE_CLI_VERSION:-0.11.0}"
proxy_url="${GATHER_BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
ocm_env="${GATHER_OCM_ENV:-staging}"

BIN_DIR="$(mktemp -d /tmp/gather-bin.XXXXXX)"
export PATH="${BIN_DIR}:${PATH}"

log "Installing ocm CLI v${ocm_ver}..."
if ! curl -sSL --fail --connect-timeout 30 --max-time 120 -o "${BIN_DIR}/ocm" \
  "https://github.com/openshift-online/ocm-cli/releases/download/v${ocm_ver}/ocm-linux-amd64"; then
  log "ERROR: Failed to download ocm CLI"
  exit 0
fi
chmod 0755 "${BIN_DIR}/ocm"

log "Installing ocm-backplane CLI v${bp_ver}..."
bp_tar="$(mktemp /tmp/ocm-backplane.XXXXXX.tar.gz)"
if ! curl -sSL --fail --connect-timeout 30 --max-time 120 -o "${bp_tar}" \
  "https://github.com/openshift/backplane-cli/releases/download/v${bp_ver}/ocm-backplane_${bp_ver}_Linux_x86_64.tar.gz"; then
  log "ERROR: Failed to download ocm-backplane CLI"
  rm -f "${bp_tar}"
  exit 0
fi
tar -xzf "${bp_tar}" -C "${BIN_DIR}" ocm-backplane 2>/dev/null || true
chmod 0755 "${BIN_DIR}/ocm-backplane" 2>/dev/null || true
rm -f "${bp_tar}"

if [[ ! -x "${BIN_DIR}/ocm-backplane" ]]; then
  log "ERROR: ocm-backplane binary not found after extraction"
  exit 0
fi

# ---- OCM login --------------------------------------------------------------

# Disable tracing for credential handling.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

OCM_TOKEN=""
if [[ -f /usr/local/cs-qe-credentials/ocm-tokens ]]; then
  # Source the tokens file (sets OCM_TOKEN or similar vars)
  # shellcheck disable=SC1091
  source /usr/local/cs-qe-credentials/ocm-tokens 2>/dev/null || true
fi

# Fall back to individual token file
if [[ -z "${OCM_TOKEN:-}" && -f /usr/local/cs-qe-credentials/ocm_token ]]; then
  OCM_TOKEN="$(cat /usr/local/cs-qe-credentials/ocm_token)"
fi

if [[ -z "${OCM_TOKEN:-}" ]]; then
  log "ERROR: No OCM token found in cs-qe-credentials. Skipping diagnostics."
  $WAS_TRACING && set -x
  exit 0
fi

case "${ocm_env}" in
  staging|stage) ocm_url="https://api.stage.openshift.com" ;;
  production|prod) ocm_url="https://api.openshift.com" ;;
  integration|int) ocm_url="https://api.integration.openshift.com" ;;
  *) ocm_url="https://api.stage.openshift.com" ;;
esac

if ! ocm login --url="${ocm_url}" --token="${OCM_TOKEN}" 2>/dev/null; then
  log "ERROR: OCM login failed"
  $WAS_TRACING && set -x
  exit 0
fi

$WAS_TRACING && set -x

log "OCM login successful (${ocm_env})"

# ---- cluster access via backplane -------------------------------------------

mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${proxy_url}" > "${HOME}/.config/backplane/config.json"

GATHER_KUBECONFIG="$(mktemp /tmp/gather-kubeconfig.XXXXXX)"
export KUBECONFIG="${GATHER_KUBECONFIG}"

log "Attempting backplane login to cluster ${CLUSTER_ID}..."
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
if ! ocm-backplane login "${CLUSTER_ID}" 2>/dev/null; then
  $WAS_TRACING && set -x
  log "WARNING: Backplane login failed. Trying OCM credentials API..."

  # Fall back to OCM credentials API
  kc_json="$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" 2>/dev/null || true)"
  kc_data="$(echo "${kc_json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kubeconfig',''))" 2>/dev/null || true)"
  if [[ -n "${kc_data}" ]]; then
    echo "${kc_data}" > "${GATHER_KUBECONFIG}"
    log "Using kubeconfig from OCM credentials API"
  else
    log "ERROR: Could not obtain cluster access. Skipping diagnostics."
    rm -f "${GATHER_KUBECONFIG}"
    exit 0
  fi
fi
$WAS_TRACING && set -x

# Verify access
if ! oc whoami > "${DIAG_DIR}/whoami.txt" 2>&1; then
  log "WARNING: oc whoami failed, cluster access may be limited"
  cat "${DIAG_DIR}/whoami.txt" 2>/dev/null || true
fi

# ---- collect oauth-apiserver diagnostics ------------------------------------

log "Collecting oauth-apiserver diagnostics..."

OAUTH_NS="openshift-oauth-apiserver"

# Pod status snapshot
log "  Pod status in ${OAUTH_NS}..."
oc get pods -n "${OAUTH_NS}" -o wide > "${DIAG_DIR}/oauth-apiserver-pods.txt" 2>&1 || true
oc get pods -n "${OAUTH_NS}" -o yaml > "${DIAG_DIR}/oauth-apiserver-pods.yaml" 2>&1 || true

# Current logs for each pod
for pod in $(oc get pods -n "${OAUTH_NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  log "  Logs for pod ${pod}..."
  oc logs -n "${OAUTH_NS}" "${pod}" --all-containers --tail=500 \
    > "${DIAG_DIR}/oauth-apiserver-${pod}.log" 2>&1 || true

  # Previous container logs (catches crash loops)
  oc logs -n "${OAUTH_NS}" "${pod}" --all-containers --previous --tail=200 \
    > "${DIAG_DIR}/oauth-apiserver-${pod}-previous.log" 2>&1 || true
done

# Events in the namespace
log "  Events in ${OAUTH_NS}..."
oc get events -n "${OAUTH_NS}" --sort-by='.lastTimestamp' \
  > "${DIAG_DIR}/oauth-apiserver-events.txt" 2>&1 || true

# ---- collect etcd diagnostics -----------------------------------------------

log "Collecting etcd diagnostics..."

ETCD_NS="openshift-etcd"

# Pod status snapshot
log "  Pod status in ${ETCD_NS}..."
oc get pods -n "${ETCD_NS}" -o wide > "${DIAG_DIR}/etcd-pods.txt" 2>&1 || true
oc get pods -n "${ETCD_NS}" -o yaml > "${DIAG_DIR}/etcd-pods.yaml" 2>&1 || true

# Logs for each etcd pod (tail to keep size manageable)
for pod in $(oc get pods -n "${ETCD_NS}" -l app=etcd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  log "  Logs for pod ${pod}..."
  oc logs -n "${ETCD_NS}" "${pod}" -c etcd --tail=500 \
    > "${DIAG_DIR}/etcd-${pod}.log" 2>&1 || true
done

# Events in the namespace
log "  Events in ${ETCD_NS}..."
oc get events -n "${ETCD_NS}" --sort-by='.lastTimestamp' \
  > "${DIAG_DIR}/etcd-events.txt" 2>&1 || true

# ---- collect authentication operator status ---------------------------------

log "Collecting authentication ClusterOperator status..."
oc get clusteroperator authentication -o yaml \
  > "${DIAG_DIR}/co-authentication.yaml" 2>&1 || true

# ---- cleanup (handled by trap) ----------------------------------------------
