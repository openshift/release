#!/usr/bin/env bash

set -euo pipefail

echo ">>> Install ACS using roxie [$(date -u || true)]"

SHARED_DIR=${SHARED_DIR:-/tmp}
KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
export KUBECONFIG

SCRATCH=$(mktemp -d)
trap 'rm -rf "${SCRATCH}"' EXIT

ROXIE_VERSION=${ROXIE_VERSION:-latest}

function install_roxie() {
  local roxie_path="${SCRATCH}/roxie"
  echo ">>> Installing roxie ${ROXIE_VERSION}"
  if [[ $ROXIE_VERSION = latest ]]; then
    roxie_url_part="latest/download"
  else
    roxie_url_part="download/v${ROXIE_VERSION}"
  fi
  local os arch
  case "$(uname -s)" in
    Linux*)  os=linux ;;
    Darwin*) os=darwin ;;
    *)       echo "Unsupported OS: $(uname -s)"; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64)       arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *)             echo "Unsupported arch: $(uname -m)"; exit 1 ;;
  esac
  curl -fsSL --retry 5 --retry-all-errors -o "${roxie_path}" \
    "https://github.com/stackrox/roxie/releases/${roxie_url_part}/roxie-${os}-${arch}"
  chmod +x "${roxie_path}"
  export PATH="${SCRATCH}:${PATH}"
  roxie version
}

install_roxie

function fetch_last_nightly_tag() {
  local acs_tag_suffix=""
  # To avoid situations where nightly is not created for the previous day (i.e. weekend),
  # we need to look more into the past.
  for days_in_past in {1..14}; do
    acs_tag_suffix="$(date -d "-${days_in_past} day" +"%Y%m%d" || gdate -d "-${days_in_past} day" +"%Y%m%d")"

    # Quay API info: https://docs.quay.io/api/swagger/#!/tag/listRepoTags
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

CENTRAL_MAX_WAIT_SECONDS="${CENTRAL_MAX_WAIT_SECONDS:-7200}"
ROX_SCANNER_V4_ENABLED="${ROX_SCANNER_V4_ENABLED:-true}"
case ${ROX_SCANNER_V4_ENABLED} in
true)
  SCANNER_V4_COMPONENT="Default" # effectively means "Enabled" in Central and "AutoSense" in SecuredCluster
  ;;
*)
  SCANNER_V4_COMPONENT="Disabled"
  ;;
esac
declare -A central_env_vars
if [[ -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
  central_env_vars[SCANNER_V4_MATCHER_READINESS]="${SCANNER_V4_MATCHER_READINESS}"
fi
if [[ -n "${SCANNER_V4_MATCHER_VULN_BUNDLE_ALLOWLIST:-}" ]]; then
  central_env_vars[SCANNER_V4_MATCHER_VULN_BUNDLE_ALLOWLIST]="${SCANNER_V4_MATCHER_VULN_BUNDLE_ALLOWLIST}"
fi

cat > "${SCRATCH}/roxie-config.yaml" <<EOF
roxie:
  # TODO(https://github.com/stackrox/roxie/issues/216)
  clusterType: InfraOpenShift4

central:
  namespace: stackrox
  earlyReadiness: false
  exposure: none
  spec:
    customize:
      envVars:
$(for v in "${!central_env_vars[@]}"; do echo "- name: $v"; echo "  value: \"${central_env_vars[$v]}\""; done | sed "s,^,      ,")
    scannerV4:
      scannerComponent: ${SCANNER_V4_COMPONENT}

securedCluster:
  namespace: stackrox
  earlyReadiness: false
  spec:
    scannerV4:
      scannerComponent: ${SCANNER_V4_COMPONENT}
EOF

extra_flags=()
if [[ "${SMALL_INSTALL:-true}" == "true" ]]; then
  extra_flags+=('--set' 'central.spec.central.resources.requests.memory=1Gi')
  extra_flags+=('--set' 'central.spec.central.resources.requests.cpu=1')
  extra_flags+=('--set' 'central.spec.central.resources.limits.memory=4Gi')
  extra_flags+=('--set' 'central.spec.central.resources.limits.cpu=1')
  extra_flags+=('--set' 'central.spec.central.db.resources.requests.memory=1Gi')
  extra_flags+=('--set' 'central.spec.central.db.resources.requests.cpu=500m')
  extra_flags+=('--set' 'central.spec.central.db.resources.limits.memory=4Gi')
  extra_flags+=('--set' 'central.spec.central.db.resources.limits.cpu=1')
  extra_flags+=('--set' 'central.spec.scanner.analyzer.scaling.autoScaling=Disabled')
  extra_flags+=('--set' 'central.spec.scanner.analyzer.scaling.replicas=1')
  extra_flags+=('--set' 'central.spec.scanner.analyzer.resources.requests.memory=500Mi')
  extra_flags+=('--set' 'central.spec.scanner.analyzer.resources.requests.cpu=500m')
  extra_flags+=('--set' 'central.spec.scanner.analyzer.resources.limits.memory=2500Mi')
  extra_flags+=('--set' 'central.spec.scanner.analyzer.resources.limits.cpu=2000m')
  if [[ "${ROX_SCANNER_V4_ENABLED}" == "true" ]]; then
    extra_flags+=('--set' 'central.spec.scannerV4.indexer.scaling.autoScaling=Disabled')
    extra_flags+=('--set' 'central.spec.scannerV4.indexer.scaling.replicas=1')
    extra_flags+=('--set' 'central.spec.scannerV4.indexer.resources.requests.cpu=600m')
    extra_flags+=('--set' 'central.spec.scannerV4.indexer.resources.requests.memory=1500Mi')
    extra_flags+=('--set' 'central.spec.scannerV4.indexer.resources.limits.cpu=1000m')
    extra_flags+=('--set' 'central.spec.scannerV4.indexer.resources.limits.memory=2Gi')
    extra_flags+=('--set' 'central.spec.scannerV4.matcher.scaling.autoScaling=Disabled')
    extra_flags+=('--set' 'central.spec.scannerV4.matcher.scaling.replicas=1')
    extra_flags+=('--set' 'central.spec.scannerV4.matcher.resources.requests.cpu=600m')
    extra_flags+=('--set' 'central.spec.scannerV4.matcher.resources.requests.memory=5Gi')
    extra_flags+=('--set' 'central.spec.scannerV4.matcher.resources.limits.cpu=1000m')
    extra_flags+=('--set' 'central.spec.scannerV4.matcher.resources.limits.memory=5500Mi')
    extra_flags+=('--set' 'central.spec.scannerV4.db.resources.requests.cpu=200m')
    extra_flags+=('--set' 'central.spec.scannerV4.db.resources.requests.memory=2Gi')
    extra_flags+=('--set' 'central.spec.scannerV4.db.resources.limits.cpu=1000m')
    extra_flags+=('--set' 'central.spec.scannerV4.db.resources.limits.memory=2500Mi')
  fi
fi

ROXIE_ENVRC="${SCRATCH}/roxie-envrc"

PUBLIC_REGISTRY="quay.io/stackrox-io"

echo ">>> Deploying ACS with roxie (tag: ${ACS_VERSION_TAG})"
roxie deploy \
  --verbose \
  --config "${SCRATCH}/roxie-config.yaml" \
  --tag "${ACS_VERSION_TAG}" \
  --envrc "${ROXIE_ENVRC}" \
  `# TODO(https://github.com/stackrox/roxie/issues/216): abort early if central pod is unhappy` \
  --central-wait "${CENTRAL_MAX_WAIT_SECONDS}s" \
  --secured-cluster-wait 75m \
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
  --operator-env "RELATED_IMAGE_FACT=${PUBLIC_REGISTRY}/fact:${ACS_VERSION_TAG}" \
  "${extra_flags[@]+"${extra_flags[@]}"}"

echo ">>> Verifying deployment"
# shellcheck disable=SC1090
source "${ROXIE_ENVRC}"
# Save admin password for use by later steps (e.g., diagnostics collection)
echo "${ROX_ADMIN_PASSWORD}" > "${SHARED_DIR}/rox_admin_password"
kubectl get nodes -o wide
kubectl get pods -o wide --namespace stackrox

echo '>>> Resource requests, limits, and scaling for stackrox deployments/daemonsets'
echo '--- Deployments ---'
kubectl get deployments -n stackrox -o json | jq '[.items[] | {name: .metadata.name, replicas: .spec.replicas, containers: [.spec.template.spec.containers[] | {name: .name, requests: .resources.requests, limits: .resources.limits}]}]'
echo '--- HorizontalPodAutoscalers ---'
kubectl get hpa -n stackrox -o json | jq '[.items[] | {name: .metadata.name, minReplicas: .spec.minReplicas, maxReplicas: .spec.maxReplicas, currentReplicas: .status.currentReplicas}]'
echo '--- DaemonSets ---'
kubectl get daemonsets -n stackrox -o json | jq '[.items[] | {name: .metadata.name, containers: [.spec.template.spec.containers[] | {name: .name, requests: .resources.requests, limits: .resources.limits}]}]'
echo '--- End resource dump ---'

echo ">>> ACS installation complete [$(date -u || true)]"
