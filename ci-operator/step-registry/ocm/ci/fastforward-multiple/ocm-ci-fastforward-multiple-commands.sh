#!/bin/bash

set -uo pipefail
shopt -s extglob

exit_code=0

# Fastforward function - performs git fast-forward for a single repo
fastforward_repo() {
  local owner=$1
  local repo=$2
  local source_branch=$3
  local dest_branch=$4
  local log_file=$5

  local ocm_dir
  ocm_dir=$(mktemp -d -t ocm-XXXXX)
  local token
  token=$(cat "${GITHUB_TOKEN_FILE}")
  local repo_url="https://${GITHUB_USER}:${token}@github.com/${owner}/${repo}.git"

  (
    cd "$ocm_dir" || exit 1
    export HOME="$ocm_dir"

    log() {
      local ts
      ts=$(date --iso-8601=seconds)
      echo "$ts" "$@"
    }

    log "INFO Cloning DESTINATION_BRANCH"
    if ! git clone -b "$dest_branch" "$repo_url" 2>&1; then
      log "INFO DESTINATION_BRANCH does not exist. Will create it"
      log "INFO Cloning SOURCE_BRANCH"
      if ! git clone -b "$source_branch" "$repo_url" 2>&1; then
        log "ERROR Could not clone SOURCE_BRANCH"
        log "      repo_url = https://github.com/${owner}/${repo}.git"
        exit 1
      fi

      log "INFO Changing into repo directory"
      cd "$repo" || exit 1

      log "INFO Checking out new DESTINATION_BRANCH"
      if ! git checkout -b "$dest_branch" 2>&1; then
        log "ERROR Could not checkout DESTINATION_BRANCH"
        exit 1
      fi

      log "INFO Pushing DESTINATION_BRANCH to origin"
      if ! git push -u origin "$dest_branch" 2>&1; then
        log "ERROR Could not push to origin DESTINATION_BRANCH"
        exit 1
      fi

      log "INFO Fast forward complete"
      exit 0
    fi

    log "INFO Changing into repo directory"
    cd "$repo" || exit 1

    log "INFO Pulling from SOURCE_BRANCH into DESTINATION_BRANCH"
    if ! git pull --ff-only origin "$source_branch" 2>&1; then
      log "ERROR Could not pull from SOURCE_BRANCH"
      exit 1
    fi

    log "INFO Pushing to origin/DESTINATION_BRANCH"
    if ! git push 2>&1; then
      log "ERROR Could not push to DESTINATION_BRANCH"
      exit 1
    fi

    log "INFO Fast forward complete"
  ) >"${log_file}" 2>&1

  local result=$?

  # Cleanup temp dir
  rm -rf "$ocm_dir" 2>/dev/null || true

  return $result
}

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

      if ! fastforward_repo "${owner}" "${repo}" "main" "${branch}" "${log_file}"; then
        err=$?
        exit_code=$((exit_code | err))
        echo "ERROR: Failed to fast-forward ${owner_repo} to branch: ${branch}"
        echo "Logs:"
        sed 's/^/    /' "${log_file}"
      fi
    done
  done
done

exit ${exit_code}
