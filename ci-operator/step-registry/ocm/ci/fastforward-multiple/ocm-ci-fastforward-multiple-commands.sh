#!/bin/bash

set -uo pipefail
shopt -s extglob

exit_code=0

# Install gh CLI if not available
install_gh_cli() {
  if command -v gh >/dev/null 2>&1; then
    echo "INFO: gh CLI already available"
    return 0
  fi

  echo "INFO: Installing gh CLI"
  local gh_version="2.62.0"
  local gh_tarball="gh_${gh_version}_linux_amd64.tar.gz"
  local gh_url="https://github.com/cli/cli/releases/download/v${gh_version}/${gh_tarball}"

  if ! curl -sL "${gh_url}" -o "/tmp/${gh_tarball}"; then
    echo "WARNING: Could not download gh CLI"
    return 1
  fi

  if ! tar -xzf "/tmp/${gh_tarball}" -C /tmp; then
    echo "WARNING: Could not extract gh CLI"
    return 1
  fi

  if ! mv "/tmp/gh_${gh_version}_linux_amd64/bin/gh" /tmp/gh; then
    echo "WARNING: Could not move gh binary"
    return 1
  fi

  chmod +x /tmp/gh
  export PATH="/tmp:${PATH}"

  if command -v gh >/dev/null 2>&1; then
    echo "INFO: gh CLI installed successfully"
    gh --version
    return 0
  else
    echo "WARNING: gh CLI installation failed"
    return 1
  fi
}

# Get default branch for a repo
get_default_branch() {
  local owner=$1
  local repo=$2
  local token

  if [[ ! -f "${GITHUB_TOKEN_FILE}" ]]; then
    echo "ERROR: GITHUB_TOKEN_FILE not found" >&2
    return 1
  fi

  token=$(cat "${GITHUB_TOKEN_FILE}")
  if [[ -z "${token}" ]]; then
    echo "ERROR: GITHUB_TOKEN_FILE is empty" >&2
    return 1
  fi

  local response http_code
  response=$(curl -s -w "\n%{http_code}" -H "Authorization: token ${token}" \
    "https://api.github.com/repos/${owner}/${repo}")
  http_code=$(echo "$response" | tail -1)
  response=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "ERROR: GitHub API returned HTTP $http_code for ${owner}/${repo}" >&2
    return 1
  fi

  # Check if repo is archived
  local archived
  archived=$(echo "$response" | jq -r '.archived')
  if [[ "$archived" == "true" ]]; then
    echo "ARCHIVED" >&2
    return 2
  fi

  local default_branch
  default_branch=$(echo "$response" | jq -r '.default_branch')

  if [[ -z "$default_branch" || "$default_branch" == "null" ]]; then
    echo "ERROR: Could not parse default_branch from API response for ${owner}/${repo}" >&2
    return 1
  fi

  echo "$default_branch"
}

# Check if branch is protected
is_branch_protected() {
  local owner=$1
  local repo=$2
  local branch=$3
  local token

  if [[ ! -f "${GITHUB_TOKEN_FILE}" ]]; then
    return 1
  fi

  token=$(cat "${GITHUB_TOKEN_FILE}")
  if [[ -z "${token}" ]]; then
    return 1
  fi

  # Check branch protection via GitHub API
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${token}" \
    "https://api.github.com/repos/${owner}/${repo}/branches/${branch}/protection")

  if [[ "$http_code" == "200" ]]; then
    return 0  # Protected
  else
    return 1  # Not protected or doesn't exist
  fi
}

# Find highest semantic version in Tekton files
# Returns version number (e.g., "217", "50") or "main" if only -main- files exist
get_highest_tekton_version() {
  local repo_dir=$1
  local product_prefix=$2  # "acm" or "mce"
  local branch_prefix=$3   # "release" or "backplane"

  if [[ ! -d "${repo_dir}/.tekton" ]]; then
    echo "0"
    return
  fi

  local highest_compact=0
  local highest_major=0
  local highest_minor=0
  local has_main_files=false

  # First pass: look for versioned files (acm-X, mce-X)
  for file in "${repo_dir}"/.tekton/*-${product_prefix}-*-*.yaml; do
    [[ -f "$file" ]] || continue

    # Extract compact version like "217" from "acm-217" or "mce-217"
    if [[ $(basename "$file") =~ ${product_prefix}-([0-9]+)- ]]; then
      local ver_compact="${BASH_REMATCH[1]}"

      # Extract semantic version from file content (e.g., "2.17" from "release-2.17")
      local semantic_version=""
      semantic_version=$(grep -oE "${branch_prefix}-[0-9]+\.[0-9]+" "$file" 2>/dev/null | head -1 | cut -d'-' -f2)

      if [[ -n "$semantic_version" ]]; then
        local major="${semantic_version%%.*}"
        local minor="${semantic_version##*.}"

        # Compare semantic versions (major.minor)
        # e.g., 5.1 > 2.17 even though 51 < 217 numerically
        if [[ $major -gt $highest_major ]] || \
           [[ $major -eq $highest_major && $minor -gt $highest_minor ]]; then
          highest_major=$major
          highest_minor=$minor
          highest_compact=$ver_compact
        fi
      else
        # Fallback to numeric comparison if can't extract semantic version
        if [[ $ver_compact -gt $highest_compact ]]; then
          highest_compact=$ver_compact
        fi
      fi
    fi
  done

  # If versioned files found, return highest
  if [[ $highest_compact -gt 0 ]]; then
    echo "$highest_compact"
    return
  fi

  # No versioned files, check for -main- pattern
  for file in "${repo_dir}"/.tekton/*-main-*.yaml; do
    [[ -f "$file" ]] || continue
    has_main_files=true
    break
  done

  if [[ "$has_main_files" == "true" ]]; then
    echo "main"
  else
    echo "0"
  fi
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

  if [[ ! -f "${GITHUB_TOKEN_FILE}" ]]; then
    echo "ERROR: GITHUB_TOKEN_FILE not found: ${GITHUB_TOKEN_FILE}" >&2
    return 1
  fi

  local token
  token=$(cat "${GITHUB_TOKEN_FILE}")

  if [[ -z "${token}" ]]; then
    echo "ERROR: GITHUB_TOKEN_FILE is empty: ${GITHUB_TOKEN_FILE}" >&2
    return 1
  fi

  local repo_url="https://${GITHUB_USER}:${token}@github.com/${owner}/${repo}.git"

  # Test log file creation before redirecting
  if ! touch "${log_file}" 2>/dev/null; then
    echo "ERROR: Cannot create log file: ${log_file}" >&2
    return 1
  fi

  # Verify log file was created
  if [[ ! -f "${log_file}" ]]; then
    echo "ERROR: Log file does not exist after touch: ${log_file}" >&2
    return 1
  fi

  # Open log file early to capture all output
  exec 3>&1 4>&2
  exec 1>>"${log_file}" 2>&1 || {
    echo "ERROR: Failed to redirect to log file: ${log_file}" >&4
    exec 1>&3 2>&4
    exec 3>&- 4>&-
    return 1
  }

  echo "INFO Starting Tekton file creation for ${owner}/${repo}"
  echo "INFO default_branch=${default_branch}, dest_versions=${dest_versions}"
  echo "INFO log_file=${log_file}"

  (
    cd "$ocm_dir" || exit 1
    export HOME="$ocm_dir"

    log() {
      local ts
      ts=$(date --iso-8601=seconds)
      echo "$ts" "$@"
    }

    log "INFO Inside subshell"
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
    highest_version=$(get_highest_tekton_version "." "${product_prefix}" "${branch_prefix}")

    if [[ "$highest_version" == "0" ]]; then
      log "INFO No existing ${product_prefix}-* or -main- Tekton files found, skipping"
      exit 0
    fi

    log "INFO Highest existing version: ${highest_version}"

    # Determine if using -main- template or versioned template
    local using_main_template=false
    local template_file
    local source_version=""

    if [[ "$highest_version" == "main" ]]; then
      using_main_template=true
      template_file=$(compgen -G ".tekton/*-main-*.yaml" | head -1)
      log "INFO Using -main- files as template"
    else
      template_file=$(compgen -G ".tekton/*-${product_prefix}-${highest_version}-*.yaml" | head -1)
      log "INFO Using ${product_prefix}-${highest_version} files as template"

      # Extract source version from template file (e.g., "release-2.17" from file content)
      if [[ -f "$template_file" ]]; then
        # Extract version from patterns like "release-2.17" or "backplane-2.17"
        # Use || true to handle grep returning 1 when no match found (pipefail would kill script)
        source_version=$(grep -oE "${branch_prefix}-[0-9]+\.[0-9]+" "$template_file" | head -1 | cut -d'-' -f2 || true)
      fi

      if [[ -z "$source_version" ]]; then
        log "WARNING Could not extract source version from template, using calculated version"
        log "INFO [DEBUG] highest_version=${highest_version}"
        # Fallback: assume format like 217 = 2.17, 50 = 5.0
        if [[ $highest_version -ge 100 ]]; then
          log "INFO [DEBUG] Calculating from 3-digit version"
          local source_major
          local source_minor
          source_major=$((highest_version / 100))
          source_minor=$((highest_version % 100))
          log "INFO [DEBUG] source_major=${source_major}, source_minor=${source_minor}"
        else
          log "INFO [DEBUG] Calculating from 2-digit version"
          local source_major
          local source_minor
          source_major=$((highest_version / 10))
          source_minor=$((highest_version % 10))
          log "INFO [DEBUG] source_major=${source_major}, source_minor=${source_minor}"
        fi
        source_version="${source_major}.${source_minor}"
        log "INFO [DEBUG] Calculated source_version=${source_version}"
      fi

      log "INFO Source version: ${branch_prefix}-${source_version}"
    fi

    # Create branch for PR
    local pr_branch="add-tekton-files-${dest_versions// /-}"

    # Check if PR branch already exists on remote
    log "INFO Checking if PR branch ${pr_branch} exists on remote"
    if git ls-remote --heads origin "${pr_branch}" | grep -q "${pr_branch}"; then
      log "INFO PR branch ${pr_branch} already exists on remote"
      log "INFO Fetching and checking out existing branch"
      if ! git fetch origin "${pr_branch}" 2>&1; then
        log "ERROR Could not fetch ${pr_branch}"
        exit 1
      fi
      if ! git checkout "${pr_branch}" 2>&1; then
        log "ERROR Could not checkout ${pr_branch}"
        exit 1
      fi
    else
      log "INFO Creating new PR branch ${pr_branch}"
      if ! git checkout -b "${pr_branch}" 2>&1; then
        log "ERROR Could not create branch ${pr_branch}"
        exit 1
      fi
    fi

    local files_created=false

    # For each destination version
    for dest_version in ${dest_versions}; do
      # Convert 5.0 -> 50, 5.1 -> 51
      local dest_ver_compact="${dest_version//./}"

      # Check if files already exist
      if compgen -G ".tekton/*-${product_prefix}-${dest_ver_compact}-*.yaml" >/dev/null; then
        log "INFO ${product_prefix}-${dest_ver_compact} files already exist, skipping"
        continue
      fi

      local dest_branch="${branch_prefix}-${dest_version}"

      if [[ "$using_main_template" == "true" ]]; then
        log "INFO Creating ${product_prefix}-${dest_ver_compact} files from -main- template"

        # Copy and transform -main- template files
        for template_file in .tekton/*-main-*.yaml; do
          [[ -f "$template_file" ]] || continue

          # Replace -main- with -acm-50- (or -mce-50-)
          local new_file="${template_file//-main-/-${product_prefix}-${dest_ver_compact}-}"

          # Transform file content:
          # 1. Replace -main with -acm-50 (or -mce-50)
          # 2. Add release branch to target_branch expression
          #    target_branch == "main" -> target_branch == "main" || target_branch == "release-5.0"
          sed -e "s/-main/-${product_prefix}-${dest_ver_compact}/g" \
              -e "s/target_branch == \"main\"/target_branch == \"main\" || target_branch == \"${dest_branch}\"/g" \
              "$template_file" > "$new_file"

          git add "$new_file"
          files_created=true
          log "INFO Created $(basename "$new_file")"
        done
      else
        log "INFO Creating ${product_prefix}-${dest_ver_compact} files from ${product_prefix}-${highest_version}"

        # Copy and transform versioned template files
        for template_file in .tekton/*-${product_prefix}-${highest_version}-*.yaml; do
          [[ -f "$template_file" ]] || continue

          local new_file="${template_file//${product_prefix}-${highest_version}/${product_prefix}-${dest_ver_compact}}"

          # Replace version strings in file content
          sed -e "s/${product_prefix}-${highest_version}/${product_prefix}-${dest_ver_compact}/g" \
              -e "s/${branch_prefix}-${source_version}/${dest_branch}/g" \
              "$template_file" > "$new_file"

          git add "$new_file"
          files_created=true
          log "INFO Created $(basename "$new_file")"
        done
      fi
    done

    # Check if PR exists for branch (even if no new files)
    local pr_title
    pr_title="Add Tekton files for ${product_prefix} versions: ${dest_versions}"
    local pr_body
    pr_body="This PR adds Tekton pipeline files for the following versions:
$(for v in ${dest_versions}; do echo "- ${product_prefix}-${v//./}"; done)

Generated from existing ${product_prefix}-${highest_version} templates.

/cc @stolostron/acm-cicd"

    local pr_exists=false
    if command -v gh >/dev/null 2>&1; then
      export GH_TOKEN="${token}"

      log "INFO Checking if PR already exists for ${pr_branch}"
      if gh pr list --head "${pr_branch}" --json number --jq '.[0].number' 2>&1 | grep -q '^[0-9]'; then
        pr_exists=true
        log "INFO PR already exists for ${pr_branch}"
      fi
    fi

    if [[ "$files_created" == "false" ]]; then
      log "INFO No new files to create"

      # Create PR if branch exists but no PR
      if [[ "$pr_exists" == "false" ]] && command -v gh >/dev/null 2>&1; then
        log "INFO Creating PR for existing branch"

        if ! gh pr create \
          --title "${pr_title}" \
          --body "${pr_body}" \
          --base "${default_branch}" \
          --head "${pr_branch}" 2>&1; then
          log "WARNING PR creation failed"
        fi
      fi

      exit 0
    fi

    # Commit changes
    log "INFO Configuring git user"
    git config user.name "OpenShift CI Robot"
    git config user.email "noreply@openshift.io"

    log "INFO Committing: Add Tekton files for versions: ${dest_versions}"
    git commit -s -m "Add Tekton files for versions: ${dest_versions}" 2>&1

    # Push branch (use -u only if new branch)
    log "INFO Pushing ${pr_branch} to origin"
    if git ls-remote --heads origin "${pr_branch}" | grep -q "${pr_branch}"; then
      # Branch exists, just push
      if ! git push 2>&1; then
        log "ERROR Could not push ${pr_branch}"
        exit 1
      fi
    else
      # New branch, set upstream
      if ! git push -u origin "${pr_branch}" 2>&1; then
        log "ERROR Could not push ${pr_branch}"
        exit 1
      fi
    fi

    # Create PR if needed
    if command -v gh >/dev/null 2>&1; then
      if [[ "$pr_exists" == "false" ]]; then
        log "INFO Creating new PR"
        log "INFO PR title: ${pr_title}"
        log "INFO PR base: ${default_branch}"
        log "INFO PR head: ${pr_branch}"

        if ! gh pr create \
          --title "${pr_title}" \
          --body "${pr_body}" \
          --base "${default_branch}" \
          --head "${pr_branch}" 2>&1; then
          log "WARNING: PR creation failed, branch pushed but PR not created"
          exit 1
        fi
      else
        log "INFO Updated files pushed to existing PR"
      fi
    else
      log "WARNING: gh CLI not available, branch pushed but PR not created"
      log "INFO Create PR manually: https://github.com/${owner}/${repo}/compare/${default_branch}...${pr_branch}"
      exit 1
    fi

    log "INFO Tekton file creation complete"
  )

  local result=$?

  # Restore stdout/stderr
  exec 1>&3 2>&4
  exec 3>&- 4>&-

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

  # Check if destination branch is protected
  local is_protected=false
  if is_branch_protected "${owner}" "${repo}" "${dest_branch}"; then
    is_protected=true
    echo "INFO: ${owner}/${repo} ${dest_branch} is protected, will use PR workflow"
  fi

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

      if [[ "${is_protected}" == "true" ]]; then
        # For protected branches, create PR instead of direct push
        local pr_branch
        pr_branch="ff-${dest_branch}-$(date +%s)"
        log "INFO Branch is protected, creating PR branch ${pr_branch}"

        if ! git checkout -b "${pr_branch}" 2>&1; then
          log "ERROR Could not create PR branch ${pr_branch}"
          exit 1
        fi

        log "INFO Pushing PR branch ${pr_branch} to origin"
        if ! git push -u origin "${pr_branch}" 2>&1; then
          log "ERROR Could not push PR branch ${pr_branch}"
          exit 1
        fi

        # Create PR using gh CLI
        if command -v gh >/dev/null 2>&1; then
          export GH_TOKEN="${token}"

          log "INFO Creating PR: ${pr_branch} -> ${dest_branch}"
          local pr_title="Fast-forward ${source_branch} to ${dest_branch}"
          local pr_body="This PR fast-forwards \`${source_branch}\` to create the new branch \`${dest_branch}\`.

/cc @stolostron/acm-cicd"

          if ! gh pr create \
            --title "${pr_title}" \
            --body "${pr_body}" \
            --base "${dest_branch}" \
            --head "${pr_branch}" 2>&1; then
            log "WARNING PR creation failed, branch pushed but PR not created"
            log "INFO Create PR manually: https://github.com/${owner}/${repo}/compare/${dest_branch}...${pr_branch}"
          fi
        else
          log "WARNING gh CLI not available, branch pushed but PR not created"
          log "INFO Create PR manually: https://github.com/${owner}/${repo}/compare/${dest_branch}...${pr_branch}"
        fi
      else
        # Direct push for non-protected branches
        log "INFO Pushing DESTINATION_BRANCH to origin"
        if ! git push -u origin "$dest_branch" 2>&1; then
          log "ERROR Could not push to origin DESTINATION_BRANCH"
          exit 1
        fi
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

    if [[ "${is_protected}" == "true" ]]; then
      # For protected branches, create PR instead of direct push
      local pr_branch
      pr_branch="ff-${dest_branch}-$(date +%s)"
      log "INFO Branch is protected, creating PR branch ${pr_branch}"

      if ! git checkout -b "${pr_branch}" 2>&1; then
        log "ERROR Could not create PR branch ${pr_branch}"
        exit 1
      fi

      log "INFO Pushing PR branch ${pr_branch} to origin"
      if ! git push -u origin "${pr_branch}" 2>&1; then
        log "ERROR Could not push PR branch ${pr_branch}"
        exit 1
      fi

      # Create PR using gh CLI
      if command -v gh >/dev/null 2>&1; then
        export GH_TOKEN="${token}"

        log "INFO Creating PR: ${pr_branch} -> ${dest_branch}"
        local pr_title="Fast-forward ${source_branch} to ${dest_branch}"
        local pr_body="This PR fast-forwards \`${source_branch}\` to \`${dest_branch}\`.

/cc @stolostron/acm-cicd"

        if ! gh pr create \
          --title "${pr_title}" \
          --body "${pr_body}" \
          --base "${dest_branch}" \
          --head "${pr_branch}" 2>&1; then
          log "WARNING PR creation failed, branch pushed but PR not created"
          log "INFO Create PR manually: https://github.com/${owner}/${repo}/compare/${dest_branch}...${pr_branch}"
        fi
      else
        log "WARNING gh CLI not available, branch pushed but PR not created"
        log "INFO Create PR manually: https://github.com/${owner}/${repo}/compare/${dest_branch}...${pr_branch}"
      fi
    else
      # Direct push for non-protected branches
      log "INFO Pushing to origin/DESTINATION_BRANCH"
      if ! git push 2>&1; then
        log "ERROR Could not push to DESTINATION_BRANCH"
        exit 1
      fi
    fi

    log "INFO Fast forward complete"
  ) >"${log_file}" 2>&1

  local result=$?

  # Cleanup temp dir
  rm -rf "$ocm_dir" 2>/dev/null || true

  return $result
}

# Install gh CLI for PR creation
install_gh_cli

echo "Fast-forward workflow inputs:
* REPO_MAP_PATH: ${REPO_MAP_PATH}
* DESTINATION_VERSIONS: ${DESTINATION_VERSIONS}
* ARTIFACT_DIR: ${ARTIFACT_DIR:-<not set>}
"

if [[ -z "${ARTIFACT_DIR:-}" ]]; then
  echo "ERROR: ARTIFACT_DIR is not set"
  exit 1
fi

if [[ ! -d "${ARTIFACT_DIR}" ]]; then
  echo "ERROR: ARTIFACT_DIR '${ARTIFACT_DIR}' is not a directory"
  exit 1
fi

if [[ ! -w "${ARTIFACT_DIR}" ]]; then
  echo "ERROR: ARTIFACT_DIR '${ARTIFACT_DIR}' is not writable"
  exit 1
fi

# Test write to verify
if ! echo "test" > "${ARTIFACT_DIR}/.write-test" 2>/dev/null; then
  echo "ERROR: Cannot write to ARTIFACT_DIR '${ARTIFACT_DIR}'"
  exit 1
fi
rm -f "${ARTIFACT_DIR}/.write-test"

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

# Repos to completely skip (no fast-forward at all)
SKIPPED_REPOS=(
  "acm-operator-bundle"
  "mce-operator-bundle"
  "cluster-proxy-addon"
  "grafana-dashboard-loader"
  "memcached"
)

# Repos with release-* default branch - exclude from main fast-forward
# These are processed separately to handle non-main default branches
EXCLUDED_REPOS=(
  "cluster-permission"
  "grafana"
  "kube-rbac-proxy"
  "kube-state-metrics"
  "memcached_exporter"
  "node-exporter"
  "prometheus"
  "prometheus-alertmanager"
  "prometheus-operator"
  "thanos"
  "thanos-receive-controller"
)

for product in mce acm; do
  component_repos=$(yq '.components[] |
      select((.bundle == "'"${product}-operator-bundle"'" or
      .name == "'"${product}-operator-bundle"'") and
      (.repository | test("^https://github\\.com/stolostron/"))).repository' "${REPO_MAP_PATH}" | sort -u)
  for repo in ${component_repos}; do
    owner_repo=${repo#https://github.com/}
    owner=${owner_repo%/*}
    repo=${owner_repo#*/}

    # Check if repo should be completely skipped
    skip=false
    for skipped in "${SKIPPED_REPOS[@]}"; do
      if [[ "${repo}" == "${skipped}" ]]; then
        skip=true
        break
      fi
    done

    if [[ "${skip}" == "true" ]]; then
      case "${repo}" in
        acm-operator-bundle|mce-operator-bundle)
          echo "INFO: Skipping ${owner_repo} (bundle repo - no fast-forward needed)"
          ;;
        cluster-proxy-addon)
          echo "INFO: Skipping ${owner_repo} (deprecated MCE 2.11)"
          ;;
        grafana-dashboard-loader)
          echo "INFO: Skipping ${owner_repo} (deprecated, moved to multicluster-observability-operator)"
          ;;
        memcached)
          echo "INFO: Skipping ${owner_repo} (deprecated, not in current manifest)"
          ;;
        *)
          echo "INFO: Skipping ${owner_repo}"
          ;;
      esac
      continue
    fi

    # Check if repo is in exclusion list (processed separately)
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

      fastforward_repo "${owner}" "${repo}" "main" "${branch}" "${log_file}"
      status=$?
      if [[ $status -ne 0 ]]; then
        exit_code=$((exit_code | status))
        echo "ERROR: Failed to fast-forward ${owner_repo} to branch: ${branch}"
        if [[ -f "${log_file}" ]]; then
          echo "Logs:"
          sed 's/^/    /' "${log_file}"
        else
          echo "ERROR: Log file not found: ${log_file}"
        fi
      fi
    done

    # After fast-forward, create Tekton files for all destination versions
    echo "INFO: Creating Tekton files for ${owner_repo}"
    tekton_log_file="${ARTIFACT_DIR}/tekton-${owner_repo//\//-}.log"

    create_tekton_files "${owner}" "${repo}" "${product}" "${branch_prefix}" "main" "${DESTINATION_VERSIONS}" "${tekton_log_file}"
    status=$?
    if [[ $status -ne 0 ]]; then
      exit_code=$((exit_code | status))
      echo "WARNING: Failed to create Tekton files for ${owner_repo}"
      if [[ -f "${tekton_log_file}" ]]; then
        echo "Logs:"
        sed 's/^/    /' "${tekton_log_file}"
      else
        echo "ERROR: Log file not found: ${tekton_log_file}"
      fi
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
      (.repository | test("^https://github\\.com/stolostron/"))).repository' "${REPO_MAP_PATH}" | sort -u)

  branch_prefix="release"
  if [[ ${product} == "mce" ]]; then
    branch_prefix="backplane"
  fi

  for repo in ${component_repos}; do
    owner_repo=${repo#https://github.com/}
    owner=${owner_repo%/*}
    repo=${owner_repo#*/}

    # Skip bundle repos entirely
    for skipped in "${SKIPPED_REPOS[@]}"; do
      if [[ "${repo}" == "${skipped}" ]]; then
        continue 2  # Continue outer loop
      fi
    done

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

    # Use natural branch prefix for product (release for ACM, backplane for MCE)
    # Exception: cluster-permission in ACM uses backplane (deprecated, moved to MCE)
    repo_branch_prefix="${branch_prefix}"
    if [[ "${repo}" == "cluster-permission" && "${product}" == "acm" ]]; then
      echo "INFO: cluster-permission deprecated in ACM, using backplane-* branches"
      repo_branch_prefix="backplane"
    fi

    # Get default branch
    default_branch=$(get_default_branch "${owner}" "${repo}" 2>&1)
    status=$?
    if [[ $status -eq 2 ]]; then
      echo "INFO: Skipping ${owner_repo} (archived repo)"
      continue
    elif [[ $status -ne 0 ]]; then
      echo "WARNING: Could not determine default branch for ${owner_repo}, skipping"
      continue
    fi

    echo "INFO: Default branch for ${owner_repo} is ${default_branch}"

    # For each destination version, ensure branch exists and create Tekton files
    for version in ${DESTINATION_VERSIONS}; do
      dest_branch="${repo_branch_prefix}-${version}"

      # Skip if dest_branch same as default_branch (no fast-forward needed)
      if [[ "${dest_branch}" == "${default_branch}" ]]; then
        echo "INFO: Skipping ${dest_branch} for ${owner_repo} (same as default branch)"
      else
        # Check if branch exists, create if not
        echo "INFO: Ensuring ${dest_branch} exists for ${owner_repo}"
        branch_log="${ARTIFACT_DIR}/create-branch-${owner_repo//\//-}-${dest_branch}.log"

        fastforward_repo "${owner}" "${repo}" "${default_branch}" "${dest_branch}" "${branch_log}"
        status=$?
        if [[ $status -ne 0 ]]; then
          exit_code=$((exit_code | status))
          echo "ERROR: Failed to ensure branch ${dest_branch} for ${owner_repo}"
          if [[ -f "${branch_log}" ]]; then
            echo "Logs:"
            sed 's/^/    /' "${branch_log}"
          else
            echo "ERROR: Log file not found: ${branch_log}"
          fi
          continue
        fi
      fi

      # Create Tekton files on the destination branch
      echo "INFO: Creating Tekton files on ${dest_branch} for ${owner_repo}"
      tekton_log_file="${ARTIFACT_DIR}/tekton-${owner_repo//\//-}-${dest_branch}.log"

      create_tekton_files "${owner}" "${repo}" "${product}" "${repo_branch_prefix}" "${default_branch}" "${version}" "${tekton_log_file}"
      status=$?
      if [[ $status -ne 0 ]]; then
        exit_code=$((exit_code | status))
        echo "WARNING: Failed to create Tekton files on ${dest_branch} for ${owner_repo}"
        if [[ -f "${tekton_log_file}" ]]; then
          echo "Logs:"
          sed 's/^/    /' "${tekton_log_file}"
        else
          echo "ERROR: Log file not found: ${tekton_log_file}"
        fi
      fi
    done

    # Special case: kube-rbac-proxy needs Tekton files on BOTH branch sets
    if [[ "${repo}" == "kube-rbac-proxy" ]]; then
      # Determine alternate prefix (release <-> backplane)
      alternate_prefix="release"
      if [[ "${branch_prefix}" == "release" ]]; then
        alternate_prefix="backplane"
      fi

      echo "INFO: kube-rbac-proxy special case - also processing ${alternate_prefix}-* branches"

      for version in ${DESTINATION_VERSIONS}; do
        dest_branch="${alternate_prefix}-${version}"

        # Skip if dest_branch same as default_branch (no fast-forward needed)
        if [[ "${dest_branch}" == "${default_branch}" ]]; then
          echo "INFO: Skipping alternate ${dest_branch} for ${owner_repo} (same as default branch)"
        else
          # Check if branch exists, create if not
          echo "INFO: Ensuring ${dest_branch} exists for ${owner_repo}"
          branch_log="${ARTIFACT_DIR}/create-branch-${owner_repo//\//-}-${dest_branch}.log"

          fastforward_repo "${owner}" "${repo}" "${default_branch}" "${dest_branch}" "${branch_log}"
          status=$?
          if [[ $status -ne 0 ]]; then
            exit_code=$((exit_code | status))
            echo "ERROR: Failed to ensure branch ${dest_branch} for ${owner_repo}"
            if [[ -f "${branch_log}" ]]; then
              echo "Logs:"
              sed 's/^/    /' "${branch_log}"
            else
              echo "ERROR: Log file not found: ${branch_log}"
            fi
            continue
          fi
        fi

        # Create Tekton files on the alternate branch
        echo "INFO: Creating Tekton files on ${dest_branch} for ${owner_repo}"
        tekton_log_file="${ARTIFACT_DIR}/tekton-${owner_repo//\//-}-${dest_branch}.log"

        create_tekton_files "${owner}" "${repo}" "${product}" "${alternate_prefix}" "${default_branch}" "${version}" "${tekton_log_file}"
        status=$?
        if [[ $status -ne 0 ]]; then
          exit_code=$((exit_code | status))
          echo "WARNING: Failed to create Tekton files on ${dest_branch} for ${owner_repo}"
          if [[ -f "${tekton_log_file}" ]]; then
            echo "Logs:"
            sed 's/^/    /' "${tekton_log_file}"
          else
            echo "ERROR: Log file not found: ${tekton_log_file}"
          fi
        fi
      done
    fi
  done
done

exit ${exit_code}
