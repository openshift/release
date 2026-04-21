#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exit_code=0

echo "DEBUG: SCRIPT_DIR=${SCRIPT_DIR}"
echo "DEBUG: BASH_SOURCE[0]=${BASH_SOURCE[0]}"
echo "DEBUG: PWD=$(pwd)"
echo "DEBUG: ls -la \${SCRIPT_DIR}:"
ls -la "${SCRIPT_DIR}" || true
echo "DEBUG: ls -la \${SCRIPT_DIR}/../fastforward:"
ls -la "${SCRIPT_DIR}/../fastforward" || true
echo "DEBUG: find step-registry scripts:"
find / -name "ocm-ci-fastforward-commands.sh" 2>/dev/null | head -5 || true
echo ""

echo "Fast-forward workflow inputs:
* REPO_MAP_PATH: ${REPO_MAP_PATH}
* DESTINATION_VERSIONS: ${DESTINATION_VERSIONS}
"

if [[ ! -f "${REPO_MAP_PATH}" ]]; then
  echo "ERROR: REPO_MAP_PATH '${REPO_MAP_PATH}' not found"
  exit 1
fi

if [[ -z "${DESTINATION_VERSIONS}" ]]; then
  echo "ERROR: DESTINATION_VERSIONS may not be empty"
  exit 1
fi

for version in ${DESTINATION_VERSIONS}; do
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version '$version' is not in X.Y format"
    exit 1
  fi
done

# Repos with release-* default branch - exclude from fast-forward
EXCLUDED_REPOS=(
  "grafana"
  "grafana-dashboard-loader"
  "kube-rbac-proxy"
  "kube-state-metrics"
  "metrics-collector"
  "node-exporter"
  "prometheus"
  "prometheus-alertmanager"
  "prometheus-operator"
  "rbac-query-proxy"
  "thanos"
  "thanos-receive-controller"
)

for product in mce acm; do
  component_repos=$(yq '.components[] |
      select((.bundle == "'"${product}-operator-bundle"'" or
      .name == "'"${product}-operator-bundle"'") and
      (.repository | test("^https://github\\.com/stolostron/"))).repository' "${REPO_MAP_PATH}")
  for repo in ${component_repos}; do
    owner_repo=${repo#https://github.com/}
    owner=${owner_repo%/*}
    repo=${owner_repo#*/}

    # Check if repo is in exclusion list
    skip=false
    for excluded in "${EXCLUDED_REPOS[@]}"; do
      if [[ "${repo}" == "${excluded}" ]]; then
        skip=true
        break
      fi
    done

    if [[ "${skip}" == "true" ]]; then
      echo "INFO: Skipping ${owner_repo} (excluded - uses release-* default branch)"
      continue
    fi

    echo "INFO: Handling ${owner_repo}"

    branch_prefix="release"
    if [[ ${product} == "mce" ]]; then
      branch_prefix="backplane"
    fi

    for version in ${DESTINATION_VERSIONS}; do
      branch="${branch_prefix}-${version}"
      echo "INFO: Fast-forwarding ${owner_repo} main to branch: ${branch}"
      log_file="${ARTIFACT_DIR}/fastforward-${owner_repo//\//-}-${branch}.log"

      REPO_OWNER=${owner} \
        REPO_NAME=${repo} \
        SOURCE_BRANCH=main \
        DESTINATION_BRANCH=${branch} \
        "${SCRIPT_DIR}/../fastforward/ocm-ci-fastforward-commands.sh" >"${log_file}" 2>&1 ||
        {
          err=$?
          exit_code=$((exit_code | err))
          echo "ERROR: Failed to fast-forward ${owner_repo} to branch: ${branch}"
          echo "Logs:"
          sed 's/^/    /' "${log_file}"
        }

      # Cleanup temp dirs created by fastforward script
      # Safe because script has completed and we're in sequential loop
      find /tmp -maxdepth 1 -name 'ocm-*' -type d -exec rm -rf {} + 2>/dev/null || true
    done
  done
done

exit ${exit_code}
