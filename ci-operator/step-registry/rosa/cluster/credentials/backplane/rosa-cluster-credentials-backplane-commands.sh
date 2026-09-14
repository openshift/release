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
ocm-backplane login "${CLUSTER_ID}"
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
