#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
proxy_url="${BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
elevate_reason="CI elevation : ${BACKPLANE_ELEVATE_REASON:-rosa-ci}"
log "Obtaining platform-plane (MC/SC) access for hosted cluster ${CLUSTER_ID}"

# Install the pinned ocm-backplane release (rosa-aws-cli provides ocm, oc, curl,
# tar, jq).
bin_dir="$(mktemp -d /tmp/backplane-bin.XXXXXX)"
export PATH="${bin_dir}:${PATH}"
bp_ver="${BACKPLANE_CLI_VERSION:-0.12.0}"
log "Installing ocm-backplane CLI v${bp_ver}"
bp_tar="$(mktemp /tmp/ocm-backplane.XXXXXX.tar.gz)"
curl -sSL --fail --connect-timeout 30 --max-time 300 -o "${bp_tar}" \
  "https://github.com/openshift/backplane-cli/releases/download/v${bp_ver}/ocm-backplane_${bp_ver}_Linux_x86_64.tar.gz"
tar -xzf "${bp_tar}" -C "${bin_dir}" ocm-backplane
chmod 0755 "${bin_dir}/ocm-backplane"
rm -f "${bp_tar}"

# Backplane reaches the corp network through the squid proxy.
mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${proxy_url}" > "${HOME}/.config/backplane/config.json"
export HTTPS_PROXY="${proxy_url}" HTTP_PROXY="${proxy_url}"
export https_proxy="${proxy_url}" http_proxy="${proxy_url}"

# Log into OCM with the cluster profile credentials.
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
  log "ERROR: no OCM credentials found in cluster profile"
  exit 1
fi
$WAS_TRACING && set -x

# ---- Management cluster kubeconfig (${SHARED_DIR}/mc-kubeconfig) ----
# Resolve the management cluster identity from OCM (name/id only), then obtain an
# elevated kubeconfig via backplane. Backplane is used instead of the OCM
# credentials API so this works for private management clusters (reached through
# the corp proxy) and produces an audited, elevated (backplane-cluster-admin)
# session in production. mc-kubeconfig is the canonical contract name
# (consolidating the older hs-mc.kubeconfig / mc-kubeconfig divergence).
MC_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/hypershift" 2>/dev/null | jq -r '.management_cluster // empty')
if [[ -z "${MC_NAME}" ]]; then
  MC_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard" 2>/dev/null | jq -r '.management_cluster // empty')
fi
if [[ -z "${MC_NAME}" ]]; then
  log "ERROR: could not resolve management cluster for ${CLUSTER_ID} (is this an HCP cluster?)"
  exit 1
fi
MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters \
                  --parameter search="name='${MC_NAME}'" --parameter size=1 \
                | jq -r '.items[0].id // empty')
if [[ -z "${MC_CLUSTER_ID}" ]]; then
  log "ERROR: could not resolve management cluster id for ${MC_NAME}"
  exit 1
fi
echo -n "${MC_NAME}" > "${SHARED_DIR}/mc-cluster-name"
echo -n "${MC_CLUSTER_ID}" > "${SHARED_DIR}/mc-cluster-id"

mc_kubeconfig="${SHARED_DIR}/mc-kubeconfig"
log "Running ocm-backplane login for management cluster ${MC_NAME} (${MC_CLUSTER_ID})"
mc_login_kubeconfig="$(mktemp /tmp/backplane-mc-login.XXXXXX)"
if ! KUBECONFIG="${mc_login_kubeconfig}" ocm-backplane login "${MC_CLUSTER_ID}"; then
  log "ERROR: ocm-backplane login failed for management cluster ${MC_CLUSTER_ID}"
  rm -f "${mc_login_kubeconfig}"
  exit 1
fi
# Verify elevation works before dumping the static kubeconfig.
KUBECONFIG="${mc_login_kubeconfig}" ocm-backplane elevate "${elevate_reason}" -- whoami
if ! KUBECONFIG="${mc_login_kubeconfig}" ocm-backplane elevate "${elevate_reason}" -- config view --raw --minify > "${mc_kubeconfig}"; then
  log "ERROR: failed to dump elevated management cluster kubeconfig"
  rm -f "${mc_kubeconfig}" "${mc_login_kubeconfig}"
  exit 1
fi
rm -f "${mc_login_kubeconfig}"
chmod 0600 "${mc_kubeconfig}"
if ! grep -q 'backplane-cluster-admin' "${mc_kubeconfig}"; then
  log "ERROR: management cluster kubeconfig missing backplane-cluster-admin impersonation"
  rm -f "${mc_kubeconfig}"
  exit 1
fi
if KUBECONFIG="${mc_kubeconfig}" oc whoami &>/dev/null; then
  log "Management cluster kubeconfig ready: ${MC_NAME} (${MC_CLUSTER_ID})"
else
  log "ERROR: management cluster kubeconfig failed validation (oc whoami)"
  rm -f "${mc_kubeconfig}"
  exit 1
fi

# ---- Service cluster kubeconfig (${SHARED_DIR}/sc-kubeconfig) ----
# The management cluster is itself managed by a service cluster. Use backplane
# multi-login to reach it. SC capture is net-new; keep it best-effort unless
# REQUIRE_SC=true so customer/MC validation still proceeds where SC is not exposed.
sc_kubeconfig="${SHARED_DIR}/sc-kubeconfig"
sc_ok=false
multi_kubeconfig="$(mktemp /tmp/backplane-multi.XXXXXX)"
if KUBECONFIG="${multi_kubeconfig}" ocm-backplane login "${MC_CLUSTER_ID}" --multi &>/dev/null; then
  # The --multi kubeconfig carries a context per reachable cluster; pick the one
  # that is not the management cluster as the service cluster.
  sc_ctx=$(KUBECONFIG="${multi_kubeconfig}" oc config get-contexts -o name 2>/dev/null \
             | grep -viE "${MC_CLUSTER_ID}|${MC_NAME}" | head -n1 || true)
  if [[ -n "${sc_ctx}" ]]; then
    if KUBECONFIG="${multi_kubeconfig}" oc config use-context "${sc_ctx}" &>/dev/null \
       && KUBECONFIG="${multi_kubeconfig}" oc config view --raw --minify > "${sc_kubeconfig}" 2>/dev/null \
       && KUBECONFIG="${sc_kubeconfig}" oc whoami &>/dev/null; then
      chmod 0600 "${sc_kubeconfig}"
      sc_ok=true
      log "Service cluster kubeconfig ready (context ${sc_ctx})"
    fi
  fi
fi
rm -f "${multi_kubeconfig}"

if [[ "${sc_ok}" != "true" ]]; then
  rm -f "${sc_kubeconfig}"
  if [[ "${REQUIRE_SC,,}" == "true" ]]; then
    log "ERROR: service cluster kubeconfig could not be produced and REQUIRE_SC=true"
    exit 1
  fi
  log "WARNING: service cluster kubeconfig unavailable; platform-plane SC checks will be skipped"
fi

log "Platform-plane access complete (mc-kubeconfig$([[ "${sc_ok}" == "true" ]] && echo ', sc-kubeconfig'))"
