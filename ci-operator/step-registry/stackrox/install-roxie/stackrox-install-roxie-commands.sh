#!/usr/bin/env bash

set -euo pipefail

echo ">>> Install ACS using roxie [$(date -u || true)]"

SHARED_DIR=${SHARED_DIR:-/tmp}
KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
export KUBECONFIG

SCRATCH=$(mktemp -d)
trap 'rm -rf "${SCRATCH}"' EXIT

ROXIE_VERSION=${ROXIE_VERSION:-0.4.2}

function install_roxie() {
  local roxie_path="${SCRATCH}/roxie"
  echo ">>> Installing roxie ${ROXIE_VERSION}"
  curl -fsSL --retry 5 --retry-all-errors -o "${roxie_path}" \
    "https://github.com/stackrox/roxie/releases/download/v${ROXIE_VERSION}/roxie-linux-amd64"
  chmod +x "${roxie_path}"
  export PATH="${SCRATCH}:${PATH}"
}

install_roxie

function fetch_last_nightly_tag() {
  local acs_tag_suffix=""
  for days_in_past in {1..14}; do
    acs_tag_suffix="$(date -d "-${days_in_past} day" +"%Y%m%d" || gdate -d "-${days_in_past} day" +"%Y%m%d")"
    ACS_VERSION_TAG=$(curl --silent "https://quay.io/api/v1/repository/stackrox-io/main/tag/?onlyActiveTags=true&limit=1&filter_tag_name=like:%-nightly-${acs_tag_suffix}" | jq '.tags[0].name' --raw-output)
    if [[ "${ACS_VERSION_TAG}" != "" && "${ACS_VERSION_TAG}" != "null" ]]; then
      break
    fi
  done
  if [[ "${ACS_VERSION_TAG}" == "" || "${ACS_VERSION_TAG}" == "null" ]]; then
    echo "Error: Unable to fetch the last nightly tag"
    exit 1
  fi
  echo "ACS_VERSION_TAG=${ACS_VERSION_TAG}"
}

ACS_VERSION_TAG=""
if [[ -f "${SHARED_DIR}/acs_image_tag" ]]; then
  ACS_VERSION_TAG="$(cat "${SHARED_DIR}/acs_image_tag")"
  echo "Using PR image tag from previous step: ${ACS_VERSION_TAG}"
else
  fetch_last_nightly_tag
fi

cat > "${SCRATCH}/roxie-config.yaml" <<'EOF'
roxie:
  # TODO(https://github.com/stackrox/roxie/issues/216)
  clusterType: InfraOpenShift4
  featureFlags:
    ROX_SCANNER_V4_ENABLED: true

central:
  namespace: stackrox
  resourceProfile: small
  earlyReadiness: false
  exposure: loadbalancer
  spec:
    customize:
      envVars:
      - name: SCANNER_V4_MATCHER_READINESS
        value: vulnerability

securedCluster:
  namespace: stackrox
  resourceProfile: small
  earlyReadiness: false
EOF

ROXIE_ENVRC="${SCRATCH}/roxie-envrc"

echo ">>> Deploying ACS with roxie (tag: ${ACS_VERSION_TAG})"
roxie deploy \
  --config "${SCRATCH}/roxie-config.yaml" \
  --tag "${ACS_VERSION_TAG}" \
  --envrc "${ROXIE_ENVRC}" \
  --central-wait 60m \
  --secured-cluster-wait 60m

echo ">>> Verifying deployment"
# shellcheck disable=SC1090
source "${ROXIE_ENVRC}"
kubectl get nodes -o wide
kubectl get pods -o wide --namespace stackrox

echo ">>> ACS installation complete [$(date -u || true)]"
