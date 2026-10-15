#!/bin/bash
set -o nounset
set -o pipefail
# Do NOT set -o errexit: this script must always exit 0 (best_effort).

log() {
  echo "[guest-kubeconfig] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

cleanup() {
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
  log "WARNING: No cluster ID in SHARED_DIR; skipping guest kubeconfig export"
  exit 0
fi

# Reuse an existing kubeconfig if a prior step already wrote one.
if [[ -s "${SHARED_DIR}/kubeconfig" ]]; then
  log "SHARED_DIR/kubeconfig already present; leaving as-is"
  exit 0
fi

for candidate in "${SHARED_DIR}/guest-kubeconfig" "${SHARED_DIR}/nested-kubeconfig"; do
  if [[ -s "${candidate}" ]]; then
    cp "${candidate}" "${SHARED_DIR}/kubeconfig"
    chmod 0600 "${SHARED_DIR}/kubeconfig"
    log "Copied ${candidate} -> SHARED_DIR/kubeconfig"
    exit 0
  fi
done

# ---- install ocm-backplane (optional fallback) ------------------------------

proxy_url="${BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
bp_ver="${BACKPLANE_CLI_VERSION:-0.12.0}"
ocm_env="${OCM_LOGIN_ENV:-staging}"

bin_dir="$(mktemp -d /tmp/guest-kc-bin.XXXXXX)"
export PATH="${bin_dir}:${PATH}"

log "Installing ocm-backplane CLI v${bp_ver}..."
bp_tar="$(mktemp /tmp/ocm-backplane.XXXXXX.tar.gz)"
if curl -sSL --fail --connect-timeout 30 --max-time 300 -o "${bp_tar}" \
  "https://github.com/openshift/backplane-cli/releases/download/v${bp_ver}/ocm-backplane_${bp_ver}_Linux_x86_64.tar.gz"; then
  tar -xzf "${bp_tar}" -C "${bin_dir}" ocm-backplane 2>/dev/null || true
  chmod 0755 "${bin_dir}/ocm-backplane" 2>/dev/null || true
fi
rm -f "${bp_tar}"

mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${proxy_url}" > "${HOME}/.config/backplane/config.json"
export HTTPS_PROXY="${proxy_url}"
export HTTP_PROXY="${proxy_url}"
export https_proxy="${proxy_url}"
export http_proxy="${proxy_url}"

# ---- OCM login --------------------------------------------------------------

[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

CRED_DIR="/usr/local/cs-qe-credentials"
SSO_CLIENT_ID=""
SSO_CLIENT_SECRET=""
OCM_TOKEN=""

if [[ -f "${CRED_DIR}/sso-client-id" && -f "${CRED_DIR}/sso-client-secret" ]]; then
  SSO_CLIENT_ID="$(cat "${CRED_DIR}/sso-client-id")"
  SSO_CLIENT_SECRET="$(cat "${CRED_DIR}/sso-client-secret")"
fi
if [[ -f "${CRED_DIR}/ocm-tokens" ]]; then
  # shellcheck disable=SC1091
  source "${CRED_DIR}/ocm-tokens" 2>/dev/null || true
fi
if [[ -z "${OCM_TOKEN:-}" && -f "${CRED_DIR}/ocm_token" ]]; then
  OCM_TOKEN="$(cat "${CRED_DIR}/ocm_token")"
fi
if [[ -z "${OCM_TOKEN:-}" && -f "${CRED_DIR}/ocm-token" ]]; then
  OCM_TOKEN="$(cat "${CRED_DIR}/ocm-token")"
fi

login_ok=false
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  if ocm login --url "${ocm_env}" \
       --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}" 2>/dev/null; then
    login_ok=true
  fi
elif [[ -n "${OCM_TOKEN:-}" ]]; then
  if ocm login --url "${ocm_env}" --token "${OCM_TOKEN}" 2>/dev/null; then
    login_ok=true
  fi
fi
$WAS_TRACING && set -x

if [[ "${login_ok}" != "true" ]]; then
  log "ERROR: OCM login failed; cannot export guest kubeconfig"
  exit 0
fi
log "OCM login successful (${ocm_env})"

# ---- prefer OCM credentials API (works without backplane roles) -------------

log "Fetching guest kubeconfig via OCM credentials API..."
kc_json="$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" 2>/dev/null || true)"
kc_data="$(echo "${kc_json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kubeconfig',''))" 2>/dev/null || true)"
if [[ -n "${kc_data}" ]]; then
  printf '%s\n' "${kc_data}" > "${SHARED_DIR}/kubeconfig"
  chmod 0600 "${SHARED_DIR}/kubeconfig"
  log "Wrote SHARED_DIR/kubeconfig from OCM credentials API"
  exit 0
fi
log "OCM credentials API did not return a kubeconfig; trying backplane login..."

# ---- backplane fallback -----------------------------------------------------

if [[ ! -x "${bin_dir}/ocm-backplane" ]]; then
  log "ERROR: ocm-backplane unavailable and credentials API failed"
  exit 0
fi

BP_KUBECONFIG="$(mktemp /tmp/bp-guest-kubeconfig.XXXXXX)"
rm -f "${BP_KUBECONFIG}"
export KUBECONFIG="${BP_KUBECONFIG}"

if ! ocm-backplane login "${CLUSTER_ID}" --proxy "${proxy_url}" 2>&1; then
  log "ERROR: Backplane guest login failed for ${CLUSTER_ID}"
  rm -f "${BP_KUBECONFIG}"
  exit 0
fi

if [[ -s "${KUBECONFIG}" ]]; then
  cp "${KUBECONFIG}" "${SHARED_DIR}/kubeconfig"
  chmod 0600 "${SHARED_DIR}/kubeconfig"
  log "Wrote SHARED_DIR/kubeconfig from backplane login"
else
  log "ERROR: Backplane login succeeded but kubeconfig file is empty"
fi
rm -f "${BP_KUBECONFIG}"
