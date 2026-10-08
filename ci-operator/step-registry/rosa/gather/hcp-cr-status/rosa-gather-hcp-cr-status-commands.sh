#!/bin/bash
set -o nounset
set -o pipefail
# Do NOT set -o errexit: this script must always exit 0 (best_effort).

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# ---- helpers ----------------------------------------------------------------

log() {
  echo "[hcp-cr-status] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Always exit 0 so the step never blocks job completion.
cleanup() {
  log "CR status collection complete."
  if [[ -d "${CR_DIR:-}" ]]; then
    log "Output files:"
    ls -lh "${CR_DIR}" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup EXIT

CR_DIR="${ARTIFACT_DIR}/cr-status"
mkdir -p "${CR_DIR}"

# ---- resolve cluster ID -----------------------------------------------------

CLUSTER_ID=""
if [[ -f "${SHARED_DIR}/cluster-id" ]]; then
  CLUSTER_ID="$(cat "${SHARED_DIR}/cluster-id" | tr -d '[:space:]')"
fi
if [[ -z "${CLUSTER_ID}" ]]; then
  log "WARNING: No cluster-id found in SHARED_DIR. Skipping CR collection."
  exit 0
fi
log "Gathering HyperShift CR statuses for cluster ${CLUSTER_ID}"

# ---- install ocm-backplane CLI ----------------------------------------------

proxy_url="${BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
elevate_reason="${BACKPLANE_ELEVATE_REASON:-https://issues.redhat.com/browse/ROSAENG-62717}"
bp_ver="${BACKPLANE_CLI_VERSION:-0.12.0}"

bin_dir="$(mktemp -d /tmp/backplane-bin.XXXXXX)"
export PATH="${bin_dir}:${PATH}"

log "Installing ocm-backplane CLI v${bp_ver}..."
bp_tar="$(mktemp /tmp/ocm-backplane.XXXXXX.tar.gz)"
if ! curl -sSL --fail --connect-timeout 30 --max-time 300 -o "${bp_tar}" \
  "https://github.com/openshift/backplane-cli/releases/download/v${bp_ver}/ocm-backplane_${bp_ver}_Linux_x86_64.tar.gz"; then
  log "ERROR: Failed to download ocm-backplane CLI"
  rm -f "${bp_tar}"
  exit 0
fi
tar -xzf "${bp_tar}" -C "${bin_dir}" ocm-backplane 2>/dev/null || true
chmod 0755 "${bin_dir}/ocm-backplane" 2>/dev/null || true
rm -f "${bp_tar}"

if [[ ! -x "${bin_dir}/ocm-backplane" ]]; then
  log "ERROR: ocm-backplane binary not found after extraction"
  exit 0
fi

# ---- configure corp proxy for backplane access ------------------------------

mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${proxy_url}" > "${HOME}/.config/backplane/config.json"
export HTTPS_PROXY="${proxy_url}"
export HTTP_PROXY="${proxy_url}"
export https_proxy="${proxy_url}"
export http_proxy="${proxy_url}"

# ---- OCM login --------------------------------------------------------------

BP_KUBECONFIG="$(mktemp /tmp/bp-kubeconfig.XXXXXX)"
rm -f "${BP_KUBECONFIG}"
export KUBECONFIG="${BP_KUBECONFIG}"

# Disable tracing for credential handling.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

# Support both SSO client credentials and offline token patterns from
# /usr/local/cs-qe-credentials (matching the backplane and gather-diagnostics
# steps). Try SSO client credentials first, fall back to OCM token.
CRED_DIR="/usr/local/cs-qe-credentials"
SSO_CLIENT_ID=""
SSO_CLIENT_SECRET=""
OCM_TOKEN=""

if [[ -f "${CRED_DIR}/sso-client-id" && -f "${CRED_DIR}/sso-client-secret" ]]; then
  SSO_CLIENT_ID="$(cat "${CRED_DIR}/sso-client-id")"
  SSO_CLIENT_SECRET="$(cat "${CRED_DIR}/sso-client-secret")"
fi

if [[ -z "${OCM_TOKEN}" && -f "${CRED_DIR}/ocm-tokens" ]]; then
  # shellcheck disable=SC1091
  source "${CRED_DIR}/ocm-tokens" 2>/dev/null || true
fi
if [[ -z "${OCM_TOKEN:-}" && -f "${CRED_DIR}/ocm_token" ]]; then
  OCM_TOKEN="$(cat "${CRED_DIR}/ocm_token")"
fi
if [[ -z "${OCM_TOKEN:-}" && -f "${CRED_DIR}/ocm-token" ]]; then
  OCM_TOKEN="$(cat "${CRED_DIR}/ocm-token")"
fi

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into OCM (${OCM_LOGIN_ENV}) with SSO credentials"
  if ! ocm login --url "${OCM_LOGIN_ENV}" \
       --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}" 2>/dev/null; then
    log "ERROR: OCM login with SSO credentials failed"
    $WAS_TRACING && set -x
    exit 0
  fi
elif [[ -n "${OCM_TOKEN:-}" ]]; then
  log "Logging into OCM (${OCM_LOGIN_ENV}) with offline token"
  if ! ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}" 2>/dev/null; then
    log "ERROR: OCM login with token failed"
    $WAS_TRACING && set -x
    exit 0
  fi
else
  log "ERROR: No OCM credentials found in ${CRED_DIR} (sso-client-id/secret or ocm-token)"
  $WAS_TRACING && set -x
  exit 0
fi
$WAS_TRACING && set -x

log "OCM login successful (${OCM_LOGIN_ENV})"

# ---- backplane login + elevate ----------------------------------------------

log "Running ocm-backplane login for ${CLUSTER_ID}..."
if ! ocm-backplane login "${CLUSTER_ID}" 2>&1; then
  log "ERROR: Backplane login failed for cluster ${CLUSTER_ID}"
  exit 0
fi

log "Elevating backplane access (reason: ${elevate_reason})..."
if ! ocm-backplane elevate "${elevate_reason}" -- config view --raw --minify > "${BP_KUBECONFIG}" 2>&1; then
  log "ERROR: Failed to get elevated backplane kubeconfig"
  rm -f "${BP_KUBECONFIG}"
  exit 0
fi
chmod 0600 "${BP_KUBECONFIG}"

# Verify access
if ! oc whoami > "${CR_DIR}/whoami.txt" 2>&1; then
  log "WARNING: oc whoami failed -- cluster access may be limited"
  cat "${CR_DIR}/whoami.txt" 2>/dev/null || true
fi

# ---- discover HC namespace on the management cluster ------------------------

log "Discovering HostedCluster namespace on the management cluster..."
HC_NS=""

hc_json=$(oc get hostedclusters.hypershift.openshift.io -A -o json 2>/dev/null) || true
if [[ -n "${hc_json}" ]]; then
  HC_NS=$(echo "${hc_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
cid = '${CLUSTER_ID}'
for item in data.get('items', []):
    meta = item.get('metadata', {})
    name = meta.get('name', '')
    ns = meta.get('namespace', '')
    spec = item.get('spec', {})
    infra_id = spec.get('infraID', '')
    cluster_id = spec.get('clusterID', '')
    # Match on name, infraID, or clusterID
    if cid in (name, infra_id, cluster_id):
        print(ns)
        break
" 2>/dev/null) || true
fi

if [[ -n "${HC_NS}" ]]; then
  log "Found HC namespace: ${HC_NS}"
else
  log "WARNING: Could not determine HC namespace -- dumping CRs from all namespaces"
fi

# ---- helper: dump a CR to a file -------------------------------------------

dump_cr() {
  local resource="$1"
  local filename="$2"
  local namespace="${3:-}"

  log "  Dumping ${resource}..."
  if [[ -n "${namespace}" ]]; then
    oc get "${resource}" -n "${namespace}" -o yaml > "${CR_DIR}/${filename}" 2>&1 || true
  else
    oc get "${resource}" -A -o yaml > "${CR_DIR}/${filename}" 2>&1 || true
  fi
}

# ---- MC-level HyperShift CRs -----------------------------------------------

log "--- Management Cluster HyperShift CR collection ---"

dump_cr "hostedclusters.hypershift.openshift.io" "hostedclusters.yaml" "${HC_NS}"
dump_cr "hostedcontrolplanes.hypershift.openshift.io" "hostedcontrolplanes.yaml" "${HC_NS}"
dump_cr "nodepools.hypershift.openshift.io" "nodepools.yaml" "${HC_NS}"
dump_cr "machines.cluster.x-k8s.io" "machines.yaml" "${HC_NS}"
dump_cr "machinedeployments.cluster.x-k8s.io" "machinedeployments.yaml" "${HC_NS}"
dump_cr "machinehealthchecks.cluster.x-k8s.io" "machinehealthchecks.yaml" "${HC_NS}"

# ---- Backup / Velero CRs ---------------------------------------------------

log "--- Backup / Velero CR collection ---"

dump_cr "backups.velero.io" "backups.yaml" ""
dump_cr "restores.velero.io" "restores.yaml" ""
dump_cr "volumesnapshots" "volumesnapshots.yaml" ""

# ---- Guest cluster CRs (if kubeconfig is available) -------------------------

GUEST_KUBECONFIG="${SHARED_DIR}/guest-kubeconfig"
# Some workflows write guest kubeconfig under different names; try common ones.
if [[ ! -f "${GUEST_KUBECONFIG}" ]]; then
  for candidate in "${SHARED_DIR}/hs-mc.kubeconfig" "${SHARED_DIR}/nested-kubeconfig"; do
    if [[ -f "${candidate}" ]]; then
      GUEST_KUBECONFIG="${candidate}"
      break
    fi
  done
fi

if [[ -f "${GUEST_KUBECONFIG}" ]]; then
  log "--- Guest cluster CR collection (kubeconfig: ${GUEST_KUBECONFIG}) ---"

  log "  Dumping nodes..."
  oc --kubeconfig="${GUEST_KUBECONFIG}" get nodes -o yaml \
    > "${CR_DIR}/guest-nodes.yaml" 2>&1 || true

  log "  Dumping certificatesigningrequests..."
  oc --kubeconfig="${GUEST_KUBECONFIG}" get certificatesigningrequests -o yaml \
    > "${CR_DIR}/guest-csrs.yaml" 2>&1 || true
else
  log "No guest cluster kubeconfig found in SHARED_DIR -- skipping guest CR collection"
fi

# ---- summary (handled by cleanup trap) --------------------------------------
