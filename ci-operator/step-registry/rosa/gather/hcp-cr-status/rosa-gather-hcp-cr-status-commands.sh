#!/bin/bash
set -o nounset
set -o pipefail
# Do NOT set -o errexit: this script must always exit 0 (best_effort).

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# ---- helpers ----------------------------------------------------------------

log() {
  echo "[hcp-cr-status] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# ---- ocm-backplane CLI acquisition ------------------------------------------
#
# The release tarball is fetched over the build farm's egress, where a single
# 504 from the CDN used to end the whole collection. The download is retried
# for transient failures only, inside one wall-clock budget for the entire
# phase, so the step can survive a blip without ever outliving the timeout the
# ref already declares. A 404 or a 403 is a settled answer, not a blip, so it
# is never retried: doing so only spends the budget that a real transient
# failure needs.
#
# Diagnostics here are deliberately fixed-field and numeric. The request URL
# can carry a signed query string, the environment can carry proxy
# credentials, and curl's own error text quotes both; this step's logs and
# artifacts are retained publicly, so none of them are ever logged, written to
# the artifact, or exposed to xtrace.
#
# Everything above the "end of sourceable definitions" marker below is free of
# top-level side effects so hack/test-rosa-gather-hcp-cr-status.sh can source
# it and exercise these functions offline. Keep it that way.

# Internal defaults and test seams, deliberately not declared in the ref's
# env list: they are not step inputs, and a job cannot set them. The offline
# test overrides them to drive the budget and backoff paths quickly.
BP_DOWNLOAD_MAX_ATTEMPTS="${BP_DOWNLOAD_MAX_ATTEMPTS:-4}"
BP_DOWNLOAD_BUDGET_SECONDS="${BP_DOWNLOAD_BUDGET_SECONDS:-300}"
BP_DOWNLOAD_CONNECT_TIMEOUT="${BP_DOWNLOAD_CONNECT_TIMEOUT:-30}"
BP_DOWNLOAD_RETRY_BASE_DELAY="${BP_DOWNLOAD_RETRY_BASE_DELAY:-5}"
BP_DOWNLOAD_RETRY_MAX_DELAY="${BP_DOWNLOAD_RETRY_MAX_DELAY:-30}"

# Indirection points for the offline test: it replaces these to drive a fake
# clock and a fake interruptible sleep instead of waiting out real backoff.
bp_now() {
  date +%s
}

bp_sleep() {
  # Sleep as a background job and wait on it. A foreground sleep would defer
  # this script's TERM handler for the whole delay -- long enough to outlast
  # the grace period the ref declares -- and would swallow the signal instead
  # of reporting it. As a job it is both reachable by that handler and
  # interruptible here, so wait returns non-zero and the caller stops.
  sleep "$1" &
  wait $!
}

# Transient enough to be worth another attempt: gateway and overload answers
# from the CDN, plus curl's connection, TLS and timeout failures. Everything
# else (404, 403, 401, malformed URL) is a fixed answer.
bp_download_is_transient() {
  local http_status="$1" curl_exit="$2"

  case "${http_status}" in
    408|425|429|500|502|503|504) return 0 ;;
  esac

  # 6 DNS, 7 connect, 16 HTTP/2, 18 partial transfer, 28 timeout,
  # 35/52/55/56 TLS handshake, empty reply, send/recv error.
  case "${curl_exit}" in
    6|7|16|18|28|35|52|55|56) return 0 ;;
  esac

  return 1
}

# Fixed-field, sanitized record of how the acquisition went, for both the
# success and the failure path. Every value is a number or one of the reason
# constants used below, so the artifact cannot carry a URL, a proxy setting or
# a transport error string.
bp_write_download_status() {
  local status_dir="$1" result="$2" reason="$3" attempts="$4" retries="$5"
  local http_status="$6" curl_exit="$7" elapsed="$8"

  [[ -d "${status_dir}" ]] || return 0
  printf 'result=%s\nreason=%s\nattempts=%s\nretries=%s\nhttp_status=%s\ncurl_exit=%s\nelapsed_seconds=%s\nmax_attempts=%s\nbudget_seconds=%s\n' \
    "${result}" "${reason}" "${attempts}" "${retries}" "${http_status}" \
    "${curl_exit}" "${elapsed}" "${BP_DOWNLOAD_MAX_ATTEMPTS}" \
    "${BP_DOWNLOAD_BUDGET_SECONDS}" \
    > "${status_dir}/backplane-cli-download.txt" 2>/dev/null || true
}

# Unpack into a staging directory and promote the binary with a rename, so
# ${bin_dir} is already on PATH but never holds a half-written ocm-backplane:
# it either has the complete binary or nothing at all.
BP_EXTRACT_REASON=""
bp_extract_backplane() {
  local archive="$1" bin_dir="$2" stage="$3"

  BP_EXTRACT_REASON=""
  rm -rf "${stage}"
  if ! mkdir -p "${stage}"; then
    BP_EXTRACT_REASON="stage_unavailable"
    return 1
  fi
  # Read the table of contents first so a truncated or corrupt body is told
  # apart from a well-formed archive that simply has no binary in it, then
  # unpack that one member and nothing else.
  if ! tar -tzf "${archive}" > /dev/null 2>&1; then
    BP_EXTRACT_REASON="archive_unreadable"
    return 1
  fi
  if ! tar -xzf "${archive}" -C "${stage}" ocm-backplane 2>/dev/null \
    || [[ ! -f "${stage}/ocm-backplane" ]]; then
    BP_EXTRACT_REASON="binary_missing"
    return 1
  fi
  if ! chmod 0755 "${stage}/ocm-backplane"; then
    BP_EXTRACT_REASON="chmod_failed"
    return 1
  fi
  if ! mv -f "${stage}/ocm-backplane" "${bin_dir}/ocm-backplane"; then
    BP_EXTRACT_REASON="install_failed"
    return 1
  fi
  return 0
}

# Returns 0 only when ${bin_dir}/ocm-backplane is in place and executable.
install_backplane_cli() {
  local version="$1" bin_dir="$2" status_dir="$3"
  local url="https://github.com/openshift/backplane-cli/releases/download/v${version}/ocm-backplane_${version}_Linux_x86_64.tar.gz"
  local work_dir archive stage started deadline now remaining delay elapsed
  local attempts=0 retries=0 http_status="000" curl_exit=0
  local result="failure" reason="not_attempted" was_tracing

  if ! work_dir="$(mktemp -d /tmp/backplane-download.XXXXXX)"; then
    bp_write_download_status "${status_dir}" failure workdir_unavailable 0 0 000 0 0
    log "ERROR: could not create a working directory for the ocm-backplane download"
    return 1
  fi
  archive="${work_dir}/ocm-backplane.tar.gz"
  stage="${work_dir}/stage"

  started="$(bp_now)"
  deadline=$((started + BP_DOWNLOAD_BUDGET_SECONDS))

  while true; do
    now="$(bp_now)"
    remaining=$((deadline - now))
    if (( remaining <= 0 )); then
      reason="budget_exhausted"
      break
    fi
    if (( attempts >= BP_DOWNLOAD_MAX_ATTEMPTS )); then
      reason="attempts_exhausted"
      break
    fi
    attempts=$((attempts + 1))

    # Drop whatever the previous attempt left behind before writing again, so
    # a truncated body is never handed to tar or promoted.
    rm -f "${archive}"

    # Keep the URL, the proxy environment and curl's error text out of the
    # log: xtrace would echo the whole command line, and -S would write the
    # transport error verbatim. Only the numeric status escapes this block.
    was_tracing=false
    [[ $- == *x* ]] && was_tracing=true
    set +x
    curl_exit=0
    http_status="$(curl -s -o "${archive}" -w '%{http_code}' \
      --fail --location --connect-timeout "${BP_DOWNLOAD_CONNECT_TIMEOUT}" \
      --max-time "${remaining}" "${url}" 2>/dev/null)" || curl_exit=$?
    $was_tracing && set -x

    # Never let anything but three digits reach the log or the artifact.
    [[ "${http_status}" =~ ^[0-9]{3}$ ]] || http_status="000"

    if (( curl_exit == 0 )); then
      if bp_extract_backplane "${archive}" "${bin_dir}" "${stage}"; then
        result="success"
        reason="ok"
      else
        reason="${BP_EXTRACT_REASON}"
      fi
      break
    fi

    if ! bp_download_is_transient "${http_status}" "${curl_exit}"; then
      reason="not_retriable"
      break
    fi

    if (( attempts >= BP_DOWNLOAD_MAX_ATTEMPTS )); then
      reason="attempts_exhausted"
      break
    fi

    delay=$((BP_DOWNLOAD_RETRY_BASE_DELAY * attempts))
    if (( delay > BP_DOWNLOAD_RETRY_MAX_DELAY )); then
      delay="${BP_DOWNLOAD_RETRY_MAX_DELAY}"
    fi
    now="$(bp_now)"
    if (( deadline - now <= delay )); then
      reason="budget_exhausted"
      break
    fi
    # A sleep cut short means the step is being torn down; stop here rather
    # than racing the grace period.
    if ! bp_sleep "${delay}"; then
      reason="interrupted"
      break
    fi
    retries=$((retries + 1))
  done

  # Always clear the staging area: a failed attempt must not leave a partial
  # archive or a half-unpacked tree behind in /tmp.
  rm -rf "${work_dir}"

  elapsed=$(( $(bp_now) - started ))
  bp_write_download_status "${status_dir}" "${result}" "${reason}" \
    "${attempts}" "${retries}" "${http_status}" "${curl_exit}" "${elapsed}"

  if [[ "${result}" == "success" ]]; then
    log "ocm-backplane CLI ready (attempts=${attempts} retries=${retries} elapsed=${elapsed}s)"
    return 0
  fi
  log "ocm-backplane CLI acquisition failed (reason=${reason} attempts=${attempts} retries=${retries} http_status=${http_status} curl_exit=${curl_exit} elapsed=${elapsed}s)"
  return 1
}

# ---- end of sourceable definitions ------------------------------------------

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
if ! install_backplane_cli "${bp_ver}" "${bin_dir}" "${CR_DIR}"; then
  log "ERROR: Failed to download ocm-backplane CLI"
  exit 0
fi

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
