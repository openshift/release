#!/bin/bash

set -o nounset
set -o pipefail

log() { echo -e "\033[1m$(date "+%H:%M:%S") $*\033[0m" >&2; }

# --- Install CLI tools ---
BIN="${HOME}/bin"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"
curl -sfSL -o "${BIN}/ocm" "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" && chmod +x "${BIN}/ocm" || true
BP_VERSION=$(curl -sfSL "https://api.github.com/repos/openshift/backplane-cli/releases/latest" | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || echo "0.11.0")
curl -sfSL "https://github.com/openshift/backplane-cli/releases/latest/download/ocm-backplane_${BP_VERSION}_Linux_x86_64.tar.gz" | tar xzf - --no-same-owner -C "${BIN}" ocm-backplane || true
curl -sfSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" | tar xzf - --no-same-owner -C "${BIN}" oc kubectl || true

NS_FILE="${SHARED_DIR}/e2e-namespace"
if [[ ! -f "${NS_FILE}" ]]; then
  log "No namespace file found, nothing to clean up"
  exit 0
fi

NS=$(cat "${NS_FILE}")
log "Cleaning up namespace: ${NS}"

# --- OCM login + backplane ---
SSO_CLIENT_ID=$(cat /usr/local/rosa-e2e-credentials/sso-client-id 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat /usr/local/rosa-e2e-credentials/sso-client-secret 2>/dev/null || true)
if ! ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"; then
  log "WARN: OCM login failed, cleanup may not work"
fi
mkdir -p "${HOME}/.config/backplane"
cat > "${HOME}/.config/backplane/config.json" <<EOF
{"proxy-url": "http://squid.corp.redhat.com:3128"}
EOF
if ! ocm backplane login "${RHOBS_CLUSTER_ID}"; then
  log "WARN: backplane login failed, cleanup may not work"
fi

ocm backplane elevate "https://redhat.atlassian.net/browse/ROSAENG-62319" 2>/dev/null || true
oce() { ocm backplane elevate "" -- "$@"; }

# Delete the namespace (cascading delete removes all resources)
if oce get namespace "${NS}" &>/dev/null; then
  log "Deleting namespace ${NS}"
  oce delete namespace "${NS}" --wait=false || true

  log "Waiting for namespace deletion"
  oce wait namespace "${NS}" --for=delete --timeout=120s 2>/dev/null || true
  log "Cleanup complete"
else
  log "Namespace ${NS} already gone"
fi
