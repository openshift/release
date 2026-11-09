#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Getting backplane access for cluster ${CLUSTER_ID}"

proxy_url="${BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
elevate_reason="${BACKPLANE_ELEVATE_REASON:-rosa-ci}"

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Install the pinned ocm-backplane release (rosa-aws-cli already provides ocm, oc,
# curl, tar, jq).
bin_dir="$(mktemp -d /tmp/backplane-bin.XXXXXX)"
export PATH="${bin_dir}:${PATH}"
bp_ver="${BACKPLANE_CLI_VERSION:-0.12.0}"
bp_asset="ocm-backplane_${bp_ver}_Linux_x86_64.tar.gz"
bp_url="https://github.com/openshift/backplane-cli/releases/download/v${bp_ver}/${bp_asset}"
bp_tar="$(mktemp /tmp/ocm-backplane.XXXXXX.tar.gz)"
bp_dl_retries="${BACKPLANE_DOWNLOAD_RETRIES:-5}"
# Upper bound on the whole download, so a hanging mirror cannot stretch the step
# to retries x --max-time.
bp_dl_max_seconds=600
bp_dl_evidence=""

# Download evidence for the step artifacts. It is deliberately limited to the
# pinned asset name, HTTP status codes, curl exit codes and timings: never
# credentials, request headers, (possibly signed) redirect targets or the
# cluster id.
write_download_diagnostics() {
  local outcome="${1}"
  if [[ -z "${ARTIFACT_DIR:-}" ]]; then
    return 0
  fi
  {
    echo "asset: ${bp_asset}"
    echo "max_attempts: ${bp_dl_retries}"
    echo "outcome: ${outcome}"
    echo "attempts:"
    printf '%s' "${bp_dl_evidence}"
    if [[ "${outcome}" != "succeeded" ]]; then
      echo "note: ocm-backplane CLI bootstrap unavailable, so this step wrote no"
      echo "      kubeconfig to SHARED_DIR and collected no cluster data."
    fi
  } > "${ARTIFACT_DIR}/backplane-cli-download.txt"
}

record_attempt() {
  local line="attempt=${1} http_code=${2:-none} curl_exit=${3} elapsed=${4}s result=${5}"
  bp_dl_evidence+="  ${line}"$'\n'
  log "ocm-backplane download ${line}"
}

# The download used to run exactly once, so a single transient gateway error
# (curl exit 22 on HTTP 504) failed the step and the whole private-cluster
# workflow. Retry the retryable failures with bounded exponential backoff, keep
# failing immediately on a permanent one (404 for an unpublished pin, 401/403
# for a blocked download), and only ever extract an archive that downloaded
# completely, so a failed or partial download is never executed.
download_backplane_cli() {
  local attempt=1 delay=5 curl_rc http_code started deadline elapsed outcome retryable
  deadline=$(( $(date +%s) + bp_dl_max_seconds ))
  while :; do
    started="$(date +%s)"
    rm -f "${bp_tar}"
    curl_rc=0
    http_code="$(curl -sSL --fail --connect-timeout 30 --max-time 300 \
      --write-out '%{http_code}' -o "${bp_tar}" "${bp_url}")" || curl_rc=$?
    elapsed=$(( $(date +%s) - started ))

    if [[ "${curl_rc}" -eq 0 ]] && tar -tzf "${bp_tar}" ocm-backplane >/dev/null 2>&1; then
      record_attempt "${attempt}" "${http_code}" "${curl_rc}" "${elapsed}" "succeeded"
      log "Installed ocm-backplane v${bp_ver} from the pinned release"
      write_download_diagnostics "succeeded"
      return 0
    fi

    # curl exit 22 means --fail rejected an HTTP status; anything else is a
    # transport-level failure. A complete download whose archive does not list
    # is truncated or corrupt, which is retryable too.
    retryable="true"
    if [[ "${curl_rc}" -eq 22 ]]; then
      case "${http_code}" in
        408|429|5??) ;;
        *) retryable="false" ;;
      esac
    elif [[ "${curl_rc}" -ne 0 ]]; then
      case "${curl_rc}" in
        # resolve, connect, partial transfer, timeout, TLS and recv failures
        6|7|16|18|28|35|52|55|56|92) ;;
        *) retryable="false" ;;
      esac
    fi

    outcome="retrying"
    if [[ "${retryable}" != "true" ]]; then
      outcome="failed-permanent"
    elif [[ "${attempt}" -ge "${bp_dl_retries}" ]] ||
         [[ $(( $(date +%s) + delay )) -ge "${deadline}" ]]; then
      outcome="failed-exhausted"
    fi
    record_attempt "${attempt}" "${http_code}" "${curl_rc}" "${elapsed}" "${outcome}"
    rm -f "${bp_tar}"

    if [[ "${outcome}" != "retrying" ]]; then
      write_download_diagnostics "${outcome}"
      return 1
    fi

    log "Retrying ocm-backplane download in ${delay}s"
    sleep "${delay}"
    delay=$(( delay * 2 ))
    if [[ "${delay}" -gt 30 ]]; then
      delay=30
    fi
    attempt=$(( attempt + 1 ))
  done
}

log "Installing ocm-backplane CLI v${bp_ver}"
if ! download_backplane_cli; then
  echo "ERROR: failed to install the pinned ocm-backplane CLI v${bp_ver}" >&2
  exit 1
fi
tar -xzf "${bp_tar}" -C "${bin_dir}" ocm-backplane
chmod 0755 "${bin_dir}/ocm-backplane"
rm -f "${bp_tar}"

# Backplane reaches the corp network through the squid proxy.
mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${proxy_url}" > "${HOME}/.config/backplane/config.json"
export HTTPS_PROXY="${proxy_url}"
export HTTP_PROXY="${proxy_url}"
export https_proxy="${proxy_url}"
export http_proxy="${proxy_url}"

# Log into OCM with the cluster profile credentials (same identity used to create
# the cluster). No dedicated backplane service account is required.
login_kubeconfig="$(mktemp /tmp/backplane-login.XXXXXX)"
rm -f "${login_kubeconfig}"
export KUBECONFIG="${login_kubeconfig}"

# Do not trace credential reads / ocm login.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into OCM (${OCM_LOGIN_ENV}) with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  log "Logging into OCM (${OCM_LOGIN_ENV}) with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  $WAS_TRACING && set -x
  echo "ERROR: no OCM credentials found in cluster profile (sso-client-id/secret or ocm-token)" >&2
  exit 1
fi
$WAS_TRACING && set -x

log "Running ocm-backplane login for ${CLUSTER_ID}"
# A freshly-ready cluster can reject the first backplane login with 406
# "failed to obtain credentials from target cluster. The cluster could be down
# or under heavy load" while the backplane agent's connection to the hosted
# cluster (and, for private clusters, the private-link endpoint) is still
# converging. Retry with backoff instead of failing the step on the first
# attempt.
bp_login_retries=${BACKPLANE_LOGIN_RETRIES:-10}
bp_login_delay=60
bp_login_ok=false
for ((bp_attempt = 1; bp_attempt <= bp_login_retries; bp_attempt++)); do
  if ocm-backplane login "${CLUSTER_ID}"; then
    bp_login_ok=true
    break
  fi
  log "ocm-backplane login attempt ${bp_attempt}/${bp_login_retries} failed"
  if (( bp_attempt < bp_login_retries )); then
    log "retrying in ${bp_login_delay}s"
    sleep "${bp_login_delay}"
  fi
done
if [[ "${bp_login_ok}" != "true" ]]; then
  log "ERROR: ocm-backplane login failed after ${bp_login_retries} attempts"
  exit 1
fi
# Verify elevation works before dumping the kubeconfig.
ocm-backplane elevate "${elevate_reason}" -- whoami

# Write a static, elevated (backplane-cluster-admin) kubeconfig for downstream
# steps. ci-operator sets KUBECONFIG=${SHARED_DIR}/kubeconfig for every step, so
# writing here gives all later oc-based steps cluster access.
out_kubeconfig="${SHARED_DIR}/kubeconfig"
if ! ocm-backplane elevate "${elevate_reason}" -- config view --raw --minify > "${out_kubeconfig}"; then
  echo "ERROR: failed to dump elevated backplane kubeconfig" >&2
  rm -f "${out_kubeconfig}"
  exit 1
fi
chmod 0600 "${out_kubeconfig}"
if ! grep -q 'backplane-cluster-admin' "${out_kubeconfig}"; then
  echo "ERROR: elevated kubeconfig missing Impersonate backplane-cluster-admin" >&2
  rm -f "${out_kubeconfig}"
  exit 1
fi

# proxy-conf.sh is sourced by the rosa wait/e2e steps so their oc traffic reaches
# the backplane endpoint through the corp proxy.
cat > "${SHARED_DIR}/proxy-conf.sh" <<EOF
export HTTPS_PROXY="${proxy_url}"
export HTTP_PROXY="${proxy_url}"
export https_proxy="${proxy_url}"
export http_proxy="${proxy_url}"
export NO_PROXY="localhost,127.0.0.1,.svc,.cluster.local"
export no_proxy="localhost,127.0.0.1,.svc,.cluster.local"
EOF

# Sanity check the produced kubeconfig can reach the cluster.
if KUBECONFIG="${out_kubeconfig}" oc whoami; then
  log "Backplane kubeconfig ready at ${out_kubeconfig}"
else
  echo "ERROR: backplane kubeconfig failed validation (oc whoami)" >&2
  exit 1
fi
