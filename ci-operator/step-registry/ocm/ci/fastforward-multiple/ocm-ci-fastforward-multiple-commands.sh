#!/bin/bash

set -uo pipefail
shopt -s extglob

exit_code=0

# Get default branch for a repo
get_default_branch() {
  local owner=$1
  local repo=$2
  local token
  token=$(cat "${GITHUB_TOKEN_FILE}")

  curl -s -H "Authorization: token ${token}" \
    "https://api.github.com/repos/${owner}/${repo}" | \
    jq -r '.default_branch'
}

# Find highest version number in Tekton files
get_highest_tekton_version() {
  local repo_dir=$1
  local product_prefix=$2  # "acm" or "mce"

  if [[ ! -d "${repo_dir}/.tekton" ]]; then
    echo "0"
    return
  fi

  local highest=0
  for file in "${repo_dir}"/.tekton/*-${product_prefix}-*-*.yaml; do
    [[ -f "$file" ]] || continue
    # Extract version like "217" from "acm-217" or "mce-217"
    if [[ $(basename "$file") =~ ${product_prefix}-([0-9]+)- ]]; then
      local ver="${BASH_REMATCH[1]}"
      if [[ $ver -gt $highest ]]; then
        highest=$ver
      fi
    fi
  done

  echo "$highest"
}

# Create Tekton files for missing versions
create_tekton_files() {
  local owner=$1
  local repo=$2
  local product=$3  # "acm" or "mce"
  local branch_prefix=$4  # "release" or "backplane"
  local default_branch=$5
  local dest_versions=$6  # Space-separated list like "5.0 5.1"
  local log_file=$7

  local product_prefix="acm"
  if [[ "${product}" == "mce" ]]; then
    product_prefix="mce"
  fi

  local ocm_dir
  ocm_dir=$(mktemp -d -t ocm-tekton-XXXXX)
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

    log "INFO Cloning ${default_branch} branch"
    if ! git clone -b "${default_branch}" "$repo_url" 2>&1; then
      log "ERROR Could not clone ${default_branch} branch"
      exit 1
    fi

    cd "$repo" || exit 1

    # Check if .tekton directory exists
    if [[ ! -d .tekton ]]; then
      log "INFO No .tekton directory found, skipping"
      exit 0
    fi

    # Find highest existing version
    local highest_version
    highest_version=$(get_highest_tekton_version "." "${product_prefix}")

    if [[ "$highest_version" == "0" ]]; then
      log "INFO No existing ${product_prefix}-* Tekton files found, skipping"
      exit 0
    fi

    log "INFO Highest existing version: ${product_prefix}-${highest_version}"

    # Determine source version branch (e.g., 2.17 from 217)
    local source_major=$((highest_version / 10))
    local source_minor=$((highest_version % 10))
    local source_version="${source_major}.${source_minor}"

    # Create branch for PR
    local pr_branch="add-tekton-files-${dest_versions// /-}"
    git checkout -b "${pr_branch}" 2>&1

    local files_created=false

    # For each destination version
    for dest_version in ${dest_versions}; do
      # Convert 5.0 -> 50, 5.1 -> 51
      local dest_ver_compact="${dest_version//./}"

      # Check if files already exist
      if ls .tekton/*-${product_prefix}-${dest_ver_compact}-*.yaml >/dev/null 2>&1; then
        log "INFO ${product_prefix}-${dest_ver_compact} files already exist, skipping"
        continue
      fi

      log "INFO Creating ${product_prefix}-${dest_ver_compact} files from ${product_prefix}-${highest_version}"

      # Copy and transform template files
      for template_file in .tekton/*-${product_prefix}-${highest_version}-*.yaml; do
        [[ -f "$template_file" ]] || continue

        local new_file="${template_file//${product_prefix}-${highest_version}/${product_prefix}-${dest_ver_compact}}"
        local dest_branch="${branch_prefix}-${dest_version}"

        # Replace version strings in file content
        sed -e "s/${product_prefix}-${highest_version}/${product_prefix}-${dest_ver_compact}/g" \
            -e "s/${branch_prefix}-${source_version}/${dest_branch}/g" \
            "$template_file" > "$new_file"

        git add "$new_file"
        files_created=true
        log "INFO Created $(basename "$new_file")"
      done
    done

    if [[ "$files_created" == "false" ]]; then
      log "INFO No new files to create"
      exit 0
    fi

    # Commit changes
    git config user.name "OpenShift CI Robot"
    git config user.email "noreply@openshift.io"
    git commit -m "Add Tekton files for versions: ${dest_versions}" 2>&1

    # Push branch
    log "INFO Pushing ${pr_branch} to origin"
    if ! git push -u origin "${pr_branch}" 2>&1; then
      log "ERROR Could not push ${pr_branch}"
      exit 1
    fi

    # Create PR using gh CLI
    log "INFO Creating PR"
    local pr_title="Add Tekton files for ${product_prefix} versions: ${dest_versions}"
    local pr_body="This PR adds Tekton pipeline files for the following versions:
$(for v in ${dest_versions}; do echo "- ${product_prefix}-${v//./}"; done)

Generated from existing ${product_prefix}-${highest_version} templates.

/cc @stolostron/acm-cicd"

    if command -v gh >/dev/null 2>&1; then
      gh pr create \
        --title "${pr_title}" \
        --body "${pr_body}" \
        --base "${default_branch}" \
        --head "${pr_branch}" 2>&1 || log "WARNING: PR creation failed, branch pushed but PR not created"
    else
      log "WARNING: gh CLI not available, branch pushed but PR not created"
      log "INFO Create PR manually: https://github.com/${owner}/${repo}/compare/${default_branch}...${pr_branch}"
    fi

    log "INFO Tekton file creation complete"
  ) >"${log_file}" 2>&1

  local result=$?

  # Cleanup temp dir
  rm -rf "$ocm_dir" 2>/dev/null || true

  return $result
}

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

    # After fast-forward, create Tekton files for all destination versions
    echo "INFO: Creating Tekton files for ${owner_repo}"
    tekton_log_file="${ARTIFACT_DIR}/tekton-${owner_repo//\//-}.log"

    if ! create_tekton_files "${owner}" "${repo}" "${product}" "${branch_prefix}" "main" "${DESTINATION_VERSIONS}" "${tekton_log_file}"; then
      err=$?
      exit_code=$((exit_code | err))
      echo "WARNING: Failed to create Tekton files for ${owner_repo}"
      echo "Logs:"
      sed 's/^/    /' "${tekton_log_file}"
    fi
  done
done

# Handle excluded repos with release-* default branch
echo ""
echo "INFO: Processing excluded repos with release-* default branch"

for product in mce acm; do
  component_repos=$(yq '.components[] |
      select((.bundle == "'"${product}-operator-bundle"'" or
      .name == "'"${product}-operator-bundle"'") and
      (.repository | test("^https://github\\.com/stolostron/"))).repository' "${REPO_MAP_PATH}")

  branch_prefix="release"
  if [[ ${product} == "mce" ]]; then
    branch_prefix="backplane"
  fi

  for repo in ${component_repos}; do
    owner_repo=${repo#https://github.com/}
    owner=${owner_repo%/*}
    repo=${owner_repo#*/}

    # Only process repos in exclusion list
    skip=true
    for excluded in "${EXCLUDED_REPOS[@]}"; do
      if [[ "${repo}" == "${excluded}" ]]; then
        skip=false
        break
      fi
    done

    if [[ "${skip}" == "true" ]]; then
      continue
    fi

    echo "INFO: Handling excluded repo ${owner_repo}"

    # Get default branch
    default_branch=$(get_default_branch "${owner}" "${repo}")
    if [[ -z "${default_branch}" ]]; then
      echo "WARNING: Could not determine default branch for ${owner_repo}, skipping"
      continue
    fi

    echo "INFO: Default branch for ${owner_repo} is ${default_branch}"

    # For each destination version, ensure branch exists and create Tekton files
    for version in ${DESTINATION_VERSIONS}; do
      dest_branch="${branch_prefix}-${version}"

      # Check if branch exists, create if not
      echo "INFO: Ensuring ${dest_branch} exists for ${owner_repo}"
      branch_log="${ARTIFACT_DIR}/create-branch-${owner_repo//\//-}-${dest_branch}.log"

      if ! fastforward_repo "${owner}" "${repo}" "${default_branch}" "${dest_branch}" "${branch_log}"; then
        err=$?
        exit_code=$((exit_code | err))
        echo "ERROR: Failed to ensure branch ${dest_branch} for ${owner_repo}"
        echo "Logs:"
        sed 's/^/    /' "${branch_log}"
        continue
      fi

      # Create Tekton files on the destination branch
      echo "INFO: Creating Tekton files on ${dest_branch} for ${owner_repo}"
      tekton_log_file="${ARTIFACT_DIR}/tekton-${owner_repo//\//-}-${dest_branch}.log"

      if ! create_tekton_files "${owner}" "${repo}" "${product}" "${branch_prefix}" "${dest_branch}" "${version}" "${tekton_log_file}"; then
        err=$?
        exit_code=$((exit_code | err))
        echo "WARNING: Failed to create Tekton files on ${dest_branch} for ${owner_repo}"
        echo "Logs:"
        sed 's/^/    /' "${tekton_log_file}"
      fi
    done
  done
done

exit ${exit_code}
