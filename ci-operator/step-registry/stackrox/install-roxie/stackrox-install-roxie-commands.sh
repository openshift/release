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
  earlyReadiness: true
  exposure: loadbalancer
  spec:
    central:
      resources:
        requests:
          cpu: "1"
          memory: 1Gi
        limits:
          cpu: "1"
          memory: 4Gi
      db:
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: "1"
            memory: 4Gi
    scanner:
      scannerComponent: Enabled
      analyzer:
        scaling:
          autoScaling: Disabled
          replicas: 1
        resources:
          requests:
            cpu: 500m
            memory: 500Mi
          limits:
            cpu: "2"
            memory: 2500Mi
      db:
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            cpu: "2"
            memory: 4Gi
    scannerV4:
      db:
        resources:
          requests:
            cpu: 200m
            memory: 2Gi
          limits:
            cpu: "1"
            memory: 2500Mi
      indexer:
        resources:
          requests:
            cpu: 600m
            memory: 1500Mi
          limits:
            cpu: "1"
            memory: 2Gi
      matcher:
        resources:
          requests:
            cpu: 600m
            memory: 5Gi
          limits:
            cpu: "1"
            memory: 5500Mi
    customize:
      envVars:
      - name: SCANNER_V4_MATCHER_READINESS
        value: vulnerability

securedCluster:
  namespace: stackrox
  earlyReadiness: true
EOF

ROXIE_ENVRC="${SCRATCH}/roxie-envrc"

PUBLIC_REGISTRY="quay.io/stackrox-io"

echo ">>> Deploying ACS with roxie (tag: ${ACS_VERSION_TAG})"
roxie deploy \
  --config "${SCRATCH}/roxie-config.yaml" \
  --tag "${ACS_VERSION_TAG}" \
  --envrc "${ROXIE_ENVRC}" \
  `# TODO(ROX-35434): simplify once roxie has 1st class support for community-branded repo` \
  --operator-env "RELATED_IMAGE_MAIN=${PUBLIC_REGISTRY}/main:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_CENTRAL_DB=${PUBLIC_REGISTRY}/central-db:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_SCANNER=${PUBLIC_REGISTRY}/scanner:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_SCANNER_SLIM=${PUBLIC_REGISTRY}/scanner-slim:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_SCANNER_DB=${PUBLIC_REGISTRY}/scanner-db:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_SCANNER_DB_SLIM=${PUBLIC_REGISTRY}/scanner-db-slim:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_COLLECTOR=${PUBLIC_REGISTRY}/collector:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_SCANNER_V4=${PUBLIC_REGISTRY}/scanner-v4:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_SCANNER_V4_DB=${PUBLIC_REGISTRY}/scanner-v4-db:${ACS_VERSION_TAG}" \
  --operator-env "RELATED_IMAGE_FACT=${PUBLIC_REGISTRY}/fact:${ACS_VERSION_TAG}"

echo ">>> Verifying deployment"
# shellcheck disable=SC1090
source "${ROXIE_ENVRC}"
echo "${ROX_ADMIN_PASSWORD}" > "${SHARED_DIR}/rox_admin_password"

echo ">>> Waiting for scanner-v4-matcher readiness"
kubectl wait pods --for=condition=Ready --selector 'app=scanner-v4-matcher' -n stackrox \
  --timeout=3600s \
  || { kubectl logs --selector 'app=scanner-v4-matcher' -n stackrox --timestamps --tail=20; exit 1; }

kubectl get nodes -o wide
kubectl get pods -o wide --namespace stackrox

echo ">>> ACS installation complete [$(date -u || true)]"
