#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log() { echo -e "\033[1m$(date "+%H:%M:%S") $*\033[0m" >&2; }

# --- Install CLI tools ---
BIN="${HOME}/bin"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"
log "Installing ocm, backplane, and oc to ${BIN}"
curl -sfSL -o "${BIN}/ocm" "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" && chmod +x "${BIN}/ocm"
BP_VERSION=$(curl -sfSL "https://api.github.com/repos/openshift/backplane-cli/releases/latest" | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'].lstrip('v'))")
curl -sfSL "https://github.com/openshift/backplane-cli/releases/latest/download/ocm-backplane_${BP_VERSION}_Linux_x86_64.tar.gz" | tar xzf - --no-same-owner -C "${BIN}" ocm-backplane
curl -sfSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" | tar xzf - --no-same-owner -C "${BIN}" oc kubectl
log "ocm: $(ocm version), backplane: $(ocm backplane version 2>&1 | head -1), oc: $(oc version --client 2>/dev/null | head -1)"

NS="rhobs-e2e-${BUILD_ID}"
log "Ephemeral namespace: ${NS}"

# --- OCM login + backplane ---
SSO_CLIENT_ID=$(cat /usr/local/rosa-e2e-credentials/sso-client-id)
SSO_CLIENT_SECRET=$(cat /usr/local/rosa-e2e-credentials/sso-client-secret)
log "Logging into OCM ${OCM_LOGIN_ENV}"
ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"

mkdir -p "${HOME}/.config/backplane"
cat > "${HOME}/.config/backplane/config.json" <<EOF
{"proxy-url": "http://squid.corp.redhat.com:3128"}
EOF
log "Backplane login to ${RHOBS_CLUSTER_ID}"
ocm backplane login "${RHOBS_CLUSTER_ID}"

# SREP backplane is read-only, elevate for write operations
ELEVATE_REASON="https://redhat.atlassian.net/browse/ROSAENG-62319"
ocm backplane elevate "${ELEVATE_REASON}"
oce() { ocm backplane elevate "" -- "$@"; }

# --- Create ephemeral namespace ---
log "Creating namespace ${NS}"
oce create namespace "${NS}"
echo "${NS}" > "${SHARED_DIR}/e2e-namespace"

oce label namespace "${NS}" \
  rhobs-e2e=true \
  prow-build-id="${BUILD_ID}" \
  --overwrite

# Add CI registry pull secret so the cell can pull pipeline images
log "Adding CI registry pull secret"
KUBECONFIG="" oc registry login --to=/tmp/ci-registry-creds.json 2>/dev/null || true
if [[ -s /tmp/ci-registry-creds.json ]]; then
  oce create secret docker-registry ci-pull-secret \
    -n "${NS}" \
    --from-file=.dockerconfigjson=/tmp/ci-registry-creds.json
  log "CI pull secret created in ${NS}"
else
  log "WARNING: could not get CI registry credentials"
fi

# Use the real synthetics-api already running on the cell
API_URL="http://synthetics-api.rhobs-int.svc:8080/probes"
echo "${API_URL}" > "${SHARED_DIR}/mock-api-url"
log "Using real API at ${API_URL}"
log "Setup complete"
