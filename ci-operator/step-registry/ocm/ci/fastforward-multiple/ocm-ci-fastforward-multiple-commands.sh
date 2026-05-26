#!/bin/bash

set -uo pipefail
shopt -s extglob

exit_code=0

# Track failures for summary report
FAILED_FASTFORWARDS=()
FAILED_TEKTON=()
SKIPPED_NO_ACCESS=()
CLEANED_BRANCHES=()
TOTAL_FASTFORWARDS=0
SUCCESSFUL_FASTFORWARDS=0
TOTAL_TEKTON=0
SUCCESSFUL_TEKTON=0
TOTAL_REPOS=0
PROCESSED_REPOS=0

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

# Extract version from branch name
# Examples: release-5.0 → 5.0, backplane-2.17 → 2.17
extract_version_from_branch() {
  local branch=$1

  if [[ "$branch" =~ ^(release|backplane)-([0-9]+\.[0-9]+)$ ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi

  # Not a versioned branch
  return 1
}

# Transform Tekton files from source version to destination version
# After fast-forward, renames and updates Tekton files for new branch
transform_tekton_files() {
  local owner=$1
  local repo=$2
  local product=$3
  local branch_prefix=$4
  local dest_branch=$5
  local source_version=$6  # e.g., "5.0"
  local dest_version=$7    # e.g., "5.1"
  local log_file=$8
  local last_release_version=$9  # e.g., "2.17" - fallback if files missing

  local product_prefix="acm"
  if [[ "${product}" == "mce" ]]; then
    product_prefix="mce"
  elif [[ "${product}" == "globalhub" ]]; then
    product_prefix="globalhub"
  fi

  # Convert versions to filename format
  # 5.0 → 50 for acm/mce, 5.0 → 5-0 for globalhub
  local source_file_version="${source_version//./}"
  local dest_file_version="${dest_version//./}"

  if [[ "${product}" == "globalhub" ]]; then
    source_file_version="${source_version//./-}"
    dest_file_version="${dest_version//./-}"
  fi

  local ocm_dir
  ocm_dir=$(mktemp -d -t ocm-transform-XXXXX)

  if [[ ! -f "${GITHUB_TOKEN_FILE}" ]]; then
    echo "ERROR: GITHUB_TOKEN_FILE not found: ${GITHUB_TOKEN_FILE}" >&2
    return 1
  fi

  local token
  token=$(cat "${GITHUB_TOKEN_FILE}")
  local repo_url="https://${GITHUB_USER}:${token}@github.com/${owner}/${repo}.git"

  # Test log file creation
  if ! touch "${log_file}" 2>/dev/null; then
    echo "ERROR: Cannot create log file: ${log_file}" >&2
    return 1
  fi

  exec 3>&1 4>&2
  exec 1>>"${log_file}" 2>&1 || {
    echo "ERROR: Failed to redirect to log file: ${log_file}" >&4
    exec 1>&3 2>&4
    exec 3>&- 4>&-
    return 1
  }

  echo "INFO: Transforming Tekton files: ${source_version} → ${dest_version} on ${dest_branch}"

  (
    cd "$ocm_dir" || exit 1
    export HOME="$ocm_dir"

    echo "INFO: Cloning ${dest_branch}"
    if ! git clone -b "${dest_branch}" "$repo_url" 2>&1; then
      echo "ERROR: Could not clone ${dest_branch}"
      exit 1
    fi

    cd "$repo" || exit 1

    if [[ ! -d .tekton ]]; then
      echo "INFO: No .tekton directory on ${dest_branch}"

      # Fallback to last_release_version if available
      if [[ -n "${last_release_version:-}" ]]; then
        local fallback_branch="${branch_prefix}-${last_release_version}"
        echo "INFO: Trying fallback to ${fallback_branch}"

        if git fetch origin "${fallback_branch}" 2>&1; then
          echo "INFO: Checking out .tekton from ${fallback_branch}"
          git checkout "origin/${fallback_branch}" -- .tekton/ 2>&1 || true

          if [[ -d .tekton ]]; then
            echo "INFO: Found .tekton from ${fallback_branch}"
          else
            echo "INFO: No .tekton on ${fallback_branch} either, skipping"
            exit 0
          fi
        else
          echo "INFO: Could not fetch ${fallback_branch}, skipping"
          exit 0
        fi
      else
        echo "INFO: LAST_RELEASE_VERSION not set, skipping"
        exit 0
      fi
    fi

    # Find files to transform
    local source_pattern="${product_prefix}-${source_file_version}-"
    local dest_pattern="${product_prefix}-${dest_file_version}-"

    local files_found=false
    local files_transformed=0

    for source_file in .tekton/${source_pattern}*.yaml; do
      if [[ ! -f "$source_file" ]]; then
        continue
      fi

      files_found=true
      local filename
      filename=$(basename "$source_file")
      local new_filename="${filename/${source_pattern}/${dest_pattern}}"
      local dest_file=".tekton/${new_filename}"

      echo "INFO: Transforming: $filename → $new_filename"

      # Rename file
      git mv "$source_file" "$dest_file"

      # Update content: version strings and branch references
      sed -i "s/${source_pattern}/${dest_pattern}/g" "$dest_file"
      sed -i "s/${branch_prefix}-${source_version}/${branch_prefix}-${dest_version}/g" "$dest_file"

      files_transformed=$((files_transformed + 1))
    done

    if [[ "$files_found" == "false" ]]; then
      echo "INFO: No ${source_pattern}*.yaml files found to transform"
      exit 0
    fi

    echo "INFO: Transformed ${files_transformed} files"

    # Commit transformation
    git config user.email "${GITHUB_USER}@users.noreply.github.com"
    git config user.name "${GITHUB_USER}"

    git commit -m "Transform Tekton files from ${source_version} to ${dest_version}

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"

    # Push
    if git push origin "${dest_branch}" 2>&1; then
      echo "SUCCESS: Pushed Tekton transformation"
      exit 0
    else
      echo "ERROR: Failed to push transformation"
      exit 1
    fi
  )

  local result=$?

  exec 1>&3 2>&4
  exec 3>&- 4>&-

  rm -rf "$ocm_dir"
  return $result
}

# Check if we have push permission to repo
can_push_to_repo() {
  local owner=$1
  local repo=$2
  local token

  if [[ ! -f "${GITHUB_TOKEN_FILE}" ]]; then
    return 1
  fi

  token=$(cat "${GITHUB_TOKEN_FILE}")
  if [[ -z "${token}" ]]; then
    return 1
  fi

  # Check repo permissions via GitHub API
  local permissions
  permissions=$(curl -s \
    -H "Authorization: token ${token}" \
    "https://api.github.com/repos/${owner}/${repo}" \
    | jq -r '.permissions.push // "false"')

  if [[ "$permissions" == "true" ]]; then
    return 0  # Has push access
  else
    return 1  # No push access
  fi
}

# Check if branch exists
branch_exists() {
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

  # Check branch via GitHub API
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${token}" \
    "https://api.github.com/repos/${owner}/${repo}/branches/${branch}")

  if [[ "$http_code" == "200" ]]; then
    return 0  # Exists
  else
    return 1  # Doesn't exist
  fi
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
# Returns version number (e.g., "217", "50", "5-0") or "main" if only -main- files exist
get_highest_tekton_version() {
  local repo_dir=$1
  local product_prefix=$2  # "acm", "mce", or "globalhub"
  local branch_prefix=$3   # "release" or "backplane"

  if [[ ! -d "${repo_dir}/.tekton" ]]; then
    echo "0"
    return
  fi

  local highest_compact=""
  local highest_major=0
  local highest_minor=0
  local has_main_files=false

  # First pass: look for versioned files (acm-X, mce-X, globalhub-X-Y)
  for file in "${repo_dir}"/.tekton/*-${product_prefix}-*-*.yaml; do
    [[ -f "$file" ]] || continue

    # Extract compact version:
    # - "50" from "acm-50-" or "mce-50-"
    # - "5-0" from "globalhub-5-0-"
    local ver_compact=""
    if [[ "${product_prefix}" == "globalhub" ]]; then
      # Match globalhub-5-0- pattern (hyphenated version)
      if [[ $(basename "$file") =~ ${product_prefix}-([0-9]+-[0-9]+)- ]]; then
        ver_compact="${BASH_REMATCH[1]}"
      fi
    else
      # Match acm-50- or mce-50- pattern (compact version)
      if [[ $(basename "$file") =~ ${product_prefix}-([0-9]+)- ]]; then
        ver_compact="${BASH_REMATCH[1]}"
      fi
    fi

    if [[ -n "$ver_compact" ]]; then

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
        # Fallback to comparison if can't extract semantic version
        if [[ "${product_prefix}" == "globalhub" ]]; then
          # For globalhub, convert hyphenated version to comparable number
          # 5-0 -> 50, 5-1 -> 51 for comparison
          local ver_num="${ver_compact//-/}"
          local highest_num="${highest_compact//-/}"
          highest_num="${highest_num:-0}"  # Default to 0 if empty
          if [[ $ver_num -gt $highest_num ]]; then
            highest_compact=$ver_compact
          fi
        else
          # Numeric comparison for acm/mce compact versions
          local curr_highest="${highest_compact:-0}"
          if [[ $ver_compact -gt $curr_highest ]]; then
            highest_compact=$ver_compact
          fi
        fi
      fi
    fi
  done

  # If versioned files found, return highest
  if [[ -n "$highest_compact" ]]; then
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
  local product=$3  # "acm", "mce", or "globalhub"
  local branch_prefix=$4  # "release" or "backplane"
  local default_branch=$5
  local dest_versions=$6  # Space-separated list like "5.0 5.1"
  local log_file=$7

  local product_prefix="acm"
  if [[ "${product}" == "mce" ]]; then
    product_prefix="mce"
  elif [[ "${product}" == "globalhub" ]]; then
    product_prefix="globalhub"
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

    # Create branch for PR
    local pr_branch="add-tekton-files-${dest_versions// /-}"

    # Check if PR branch already exists on remote BEFORE doing any file operations
    local branch_existed_on_remote=false
    log "INFO Checking if PR branch ${pr_branch} exists on remote"
    if git ls-remote --heads origin "${pr_branch}" | grep -q "${pr_branch}"; then
      branch_existed_on_remote=true
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

      # Check if HEAD commit has DCO sign-off, amend if missing
      log "INFO Checking DCO sign-off on existing commit"
      if ! git log -1 --pretty=%B | grep -q "^Signed-off-by:"; then
        log "INFO Missing DCO sign-off, amending commit"
        git config user.name "OpenShift CI Robot"
        git config user.email "noreply@openshift.io"
        if ! git commit --amend -s --no-edit 2>&1; then
          log "WARNING Could not amend commit with DCO"
        else
          log "INFO Force pushing amended commit"
          if ! git push --force 2>&1; then
            log "WARNING Could not force push amended commit"
          fi
        fi
      fi
    else
      log "INFO Creating new PR branch ${pr_branch}"
      if ! git checkout -b "${pr_branch}" 2>&1; then
        log "ERROR Could not create branch ${pr_branch}"
        exit 1
      fi
    fi

    # Now that we're on the correct branch (either existing PR or new branch),
    # find highest existing version (returns "0" if no .tekton directory)
    local highest_version
    highest_version=$(get_highest_tekton_version "." "${product_prefix}" "${branch_prefix}")

    if [[ "$highest_version" == "0" ]] && [[ -n "${LAST_RELEASE_VERSION:-}" ]]; then
      # No Tekton files on current branch, try fallback to LAST_RELEASE_VERSION
      log "INFO No Tekton files on ${default_branch}, trying fallback to LAST_RELEASE_VERSION=${LAST_RELEASE_VERSION}"

      local last_release_branch="${branch_prefix}-${LAST_RELEASE_VERSION}"
      log "INFO Fetching template from ${last_release_branch}"

      if git fetch origin "${last_release_branch}" 2>&1; then
        log "INFO Checking out Tekton files from ${last_release_branch}"
        # Try to checkout .tekton directory from last release branch
        git checkout "origin/${last_release_branch}" -- .tekton/ 2>&1 || true

        # Recheck for templates
        highest_version=$(get_highest_tekton_version "." "${product_prefix}" "${branch_prefix}")

        if [[ "$highest_version" != "0" ]]; then
          log "INFO Found Tekton files from ${last_release_branch} (version ${highest_version})"
        else
          log "WARNING No Tekton files found on ${last_release_branch} either"
        fi
      else
        log "WARNING Could not fetch ${last_release_branch}"
      fi
    fi

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

    local files_created=false

    # For each destination version
    for dest_version in ${dest_versions}; do
      # Convert version: ACM/MCE: 5.0 -> 50, Global Hub: 5.0 -> 5-0
      local dest_ver_compact
      if [[ "${product}" == "globalhub" ]]; then
        dest_ver_compact="${dest_version//./-}"  # 5.0 -> 5-0
      else
        dest_ver_compact="${dest_version//./}"   # 5.0 -> 50
      fi

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

Generated from existing ${product_prefix}-${highest_version} templates."

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

      # Create PR if branch existed on remote (has commits) but no PR
      if [[ "$pr_exists" == "false" ]] && [[ "$branch_existed_on_remote" == "true" ]] && command -v gh >/dev/null 2>&1; then
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

  # Check if destination branch is protected (for logging only)
  if is_branch_protected "${owner}" "${repo}" "${dest_branch}"; then
    echo "INFO: ${owner}/${repo} ${dest_branch} is protected (will try direct push with bot bypass)"
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

      # Push new branch to origin
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

    # Push to origin
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

# Install gh CLI for PR creation
install_gh_cli

echo "Fast-forward workflow inputs:
* REPO_MAP_PATH: ${REPO_MAP_PATH}
* DESTINATION_VERSIONS: ${DESTINATION_VERSIONS}
* LAST_RELEASE_VERSION: ${LAST_RELEASE_VERSION:-<not set>}
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
# EXCLUDED_REPOS list is no longer needed - auto-detect based on default branch
# Repos with non-main default branch (e.g., release-5.0) are handled automatically
# Previously hardcoded list included:
#   cloudevents-conductor, cluster-permission, grafana, kube-rbac-proxy,
#   kube-state-metrics, maestro, memcached_exporter, obo-prometheus-operator,
#   node-exporter, prometheus, prometheus-alertmanager, prometheus-operator,
#   thanos, thanos-receive-controller

for product in mce acm globalhub; do
  # Print section header
  echo ""
  if [[ "${product}" == "mce" ]]; then
    echo "=== Processing MCE repos (main → backplane-*) ==="
  elif [[ "${product}" == "globalhub" ]]; then
    echo "=== Processing Global Hub repos (main → release-*) ==="
  else
    echo "=== Processing ACM repos (main → release-*) ==="
  fi
  echo ""

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

    echo "INFO: Handling ${owner_repo}"
    TOTAL_REPOS=$((TOTAL_REPOS + 1))

    # Check if we have push access to repo
    if ! can_push_to_repo "${owner}" "${repo}"; then
      SKIPPED_NO_ACCESS+=("${owner_repo}")
      echo "INFO: Skipping ${owner_repo} (no write access - likely fork/external repo)"
      continue
    fi

    PROCESSED_REPOS=$((PROCESSED_REPOS + 1))

    # Get default branch to determine routing
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

    branch_prefix="release"
    if [[ ${product} == "mce" ]]; then
      branch_prefix="backplane"
    elif [[ ${product} == "globalhub" ]]; then
      branch_prefix="release"
    fi

    # Route based on default branch
    # Normal repos: default = main/master → fast-forward main to release-X.Y
    # Excluded repos: default = release-X.Y → fast-forward default to other release-X.Y
    if [[ "${default_branch}" == "main" ]] || [[ "${default_branch}" == "master" ]]; then
      # NORMAL REPO HANDLING: default branch is main/master
      echo "INFO: Using normal fast-forward (${default_branch} → release branches)"

      for version in ${DESTINATION_VERSIONS}; do
        branch="${branch_prefix}-${version}"
        echo "INFO: Fast-forwarding ${owner_repo} ${default_branch} → ${branch}"
        log_file="${ARTIFACT_DIR}/fastforward-${owner_repo//\//-}-${branch}.log"

        TOTAL_FASTFORWARDS=$((TOTAL_FASTFORWARDS + 1))

        # Call fastforward_repo and capture status
        # Explicitly handle to prevent any exit propagation
        if fastforward_repo "${owner}" "${repo}" "${default_branch}" "${branch}" "${log_file}"; then
          status=0
        else
          status=$?
        fi

        if [[ $status -ne 0 ]]; then
          exit_code=$((exit_code | status))
          FAILED_FASTFORWARDS+=("${owner_repo} ${default_branch} → ${branch}")
          echo "ERROR: Failed to fast-forward ${owner_repo} ${default_branch} → ${branch}"
          if [[ -f "${log_file}" ]]; then
            echo "  Last 10 lines of log:"
            tail -10 "${log_file}" | sed 's/^/    /'
          else
            echo "  ERROR: Log file not found: ${log_file}"
          fi
        else
          SUCCESSFUL_FASTFORWARDS=$((SUCCESSFUL_FASTFORWARDS + 1))
          echo "SUCCESS: Fast-forwarded ${owner_repo} ${default_branch} → ${branch}"
        fi
      done

      # After fast-forward, create Tekton files for all destination versions
      echo "INFO: Creating Tekton files for ${owner_repo}"
      tekton_log_file="${ARTIFACT_DIR}/tekton-${owner_repo//\//-}.log"

      TOTAL_TEKTON=$((TOTAL_TEKTON + 1))

      if create_tekton_files "${owner}" "${repo}" "${product}" "${branch_prefix}" "${default_branch}" "${DESTINATION_VERSIONS}" "${tekton_log_file}"; then
        status=0
      else
        status=$?
      fi

      if [[ $status -ne 0 ]]; then
        exit_code=$((exit_code | status))
        FAILED_TEKTON+=("${owner_repo} (${default_branch} branch)")
        echo "ERROR: Failed to create Tekton files for ${owner_repo}"
        if [[ -f "${tekton_log_file}" ]]; then
          echo "  Last 10 lines of log:"
          tail -10 "${tekton_log_file}" | sed 's/^/    /'
        else
          echo "  ERROR: Log file not found: ${tekton_log_file}"
        fi
      else
        SUCCESSFUL_TEKTON=$((SUCCESSFUL_TEKTON + 1))
        echo "SUCCESS: Created Tekton files for ${owner_repo}"
      fi

    else
      # EXCLUDED REPO HANDLING: default branch is NOT main/master (e.g., release-5.0)
      echo "INFO: Using excluded repo logic (${default_branch} → other release branches)"

      # Use natural branch prefix for product (release for ACM, backplane for MCE)
      # Exception: cluster-permission in ACM uses backplane (deprecated, moved to MCE)
      repo_branch_prefix="${branch_prefix}"
      if [[ "${repo}" == "cluster-permission" && "${product}" == "acm" ]]; then
        echo "INFO: cluster-permission deprecated in ACM, using backplane-* branches"
        repo_branch_prefix="backplane"
      fi

      # Extract version from default branch name
      default_version=$(extract_version_from_branch "${default_branch}")
      if [[ -z "$default_version" ]]; then
        echo "WARNING: Could not extract version from ${default_branch}, skipping ${owner_repo}"
        continue
      fi

      echo "INFO: Default branch version: ${default_version}"

      # Create Tekton files ONLY on default branch for default version ONLY
      echo "INFO: Creating Tekton files for ${owner_repo} on ${default_branch} (version ${default_version})"
      tekton_log_file="${ARTIFACT_DIR}/tekton-${owner_repo//\//-}-${default_branch}.log"

      TOTAL_TEKTON=$((TOTAL_TEKTON + 1))

      if create_tekton_files "${owner}" "${repo}" "${product}" "${repo_branch_prefix}" "${default_branch}" "${default_version}" "${tekton_log_file}"; then
        status=0
      else
        status=$?
      fi

      if [[ $status -ne 0 ]]; then
        exit_code=$((exit_code | status))
        FAILED_TEKTON+=("${owner_repo} (${default_branch}, version ${default_version})")
        echo "ERROR: Failed to create Tekton files for ${owner_repo}"
        if [[ -f "${tekton_log_file}" ]]; then
          echo "  Last 10 lines of log:"
          tail -10 "${tekton_log_file}" | sed 's/^/    /'
        else
          echo "  ERROR: Log file not found: ${tekton_log_file}"
        fi
      else
        SUCCESSFUL_TEKTON=$((SUCCESSFUL_TEKTON + 1))
        echo "SUCCESS: Created Tekton files for ${owner_repo} on ${default_branch}"
      fi

      # Special case: kube-rbac-proxy needs BOTH ACM and MCE Tekton files on same branch
      if [[ "${repo}" == "kube-rbac-proxy" ]]; then
        # Determine alternate product and prefix
        alternate_product="mce"
        alternate_prefix="backplane"
        if [[ "${product}" == "mce" ]]; then
          alternate_product="acm"
          alternate_prefix="release"
        fi

        echo "INFO: kube-rbac-proxy - also creating ${alternate_product} Tekton files on ${default_branch}"
        tekton_log_file_alt="${ARTIFACT_DIR}/tekton-${owner_repo//\//-}-${default_branch}-alt.log"

        TOTAL_TEKTON=$((TOTAL_TEKTON + 1))

        if create_tekton_files "${owner}" "${repo}" "${alternate_product}" "${alternate_prefix}" "${default_branch}" "${default_version}" "${tekton_log_file_alt}"; then
          status=0
        else
          status=$?
        fi

        if [[ $status -ne 0 ]]; then
          exit_code=$((exit_code | status))
          FAILED_TEKTON+=("${owner_repo} (${default_branch}, ${alternate_product}, version ${default_version})")
          echo "ERROR: Failed to create ${alternate_product} Tekton files for ${owner_repo}"
          if [[ -f "${tekton_log_file_alt}" ]]; then
            echo "  Last 10 lines of log:"
            tail -10 "${tekton_log_file_alt}" | sed 's/^/    /'
          else
            echo "  ERROR: Log file not found: ${tekton_log_file_alt}"
          fi
        else
          SUCCESSFUL_TEKTON=$((SUCCESSFUL_TEKTON + 1))
          echo "SUCCESS: Created ${alternate_product} Tekton files for ${owner_repo} on ${default_branch}"
        fi
      fi

      # Fast-forward to destination branches and transform Tekton files
      for version in ${DESTINATION_VERSIONS}; do
        dest_branch="${repo_branch_prefix}-${version}"

        # Skip if dest_branch same as default_branch
        if [[ "${dest_branch}" == "${default_branch}" ]]; then
          echo "INFO: Skipping ${dest_branch} (same as default branch)"
          continue
        fi

        # Fast-forward from default branch (creates branch if doesn't exist)
        echo "INFO: Fast-forwarding ${default_branch} → ${dest_branch} for ${owner_repo}"
        branch_log="${ARTIFACT_DIR}/fastforward-${owner_repo//\//-}-${dest_branch}.log"

        TOTAL_FASTFORWARDS=$((TOTAL_FASTFORWARDS + 1))

        if fastforward_repo "${owner}" "${repo}" "${default_branch}" "${dest_branch}" "${branch_log}"; then
          status=0
        else
          status=$?
        fi

        if [[ $status -ne 0 ]]; then
          FAILED_FASTFORWARDS+=("${owner_repo} ${default_branch} → ${dest_branch}")
          echo "ERROR: Failed to fast-forward ${owner_repo} ${default_branch} → ${dest_branch}"
          if [[ -f "${branch_log}" ]]; then
            echo "  Last 10 lines of log:"
            tail -10 "${branch_log}" | sed 's/^/    /'
          fi
          continue
        fi

        SUCCESSFUL_FASTFORWARDS=$((SUCCESSFUL_FASTFORWARDS + 1))
        echo "SUCCESS: Fast-forwarded ${owner_repo} ${default_branch} → ${dest_branch}"

        # Transform Tekton files from default_version to version
        echo "INFO: Transforming Tekton files ${default_version} → ${version} on ${dest_branch}"
        transform_log="${ARTIFACT_DIR}/transform-${owner_repo//\//-}-${dest_branch}.log"

        TOTAL_TEKTON=$((TOTAL_TEKTON + 1))

        if transform_tekton_files "${owner}" "${repo}" "${product}" "${repo_branch_prefix}" "${dest_branch}" "${default_version}" "${version}" "${transform_log}" "${LAST_RELEASE_VERSION:-}"; then
          status=0
        else
          status=$?
        fi

        if [[ $status -ne 0 ]]; then
          exit_code=$((exit_code | status))
          FAILED_TEKTON+=("${owner_repo} (transform ${default_version} → ${version} on ${dest_branch})")
          echo "ERROR: Failed to transform Tekton files for ${owner_repo}"
          if [[ -f "${transform_log}" ]]; then
            echo "  Last 10 lines of log:"
            tail -10 "${transform_log}" | sed 's/^/    /'
          else
            echo "  ERROR: Log file not found: ${transform_log}"
          fi
        else
          SUCCESSFUL_TEKTON=$((SUCCESSFUL_TEKTON + 1))
          echo "SUCCESS: Transformed Tekton files for ${owner_repo} on ${dest_branch}"
        fi

        # Special case: kube-rbac-proxy also transform alternate product files
        if [[ "${repo}" == "kube-rbac-proxy" ]]; then
          # Determine alternate product and prefix
          alternate_product="mce"
          alternate_prefix="backplane"
          if [[ "${product}" == "mce" ]]; then
            alternate_product="acm"
            alternate_prefix="release"
          fi

          echo "INFO: kube-rbac-proxy - transforming ${alternate_product} files ${default_version} → ${version} on ${dest_branch}"
          transform_log_alt="${ARTIFACT_DIR}/transform-${owner_repo//\//-}-${dest_branch}-alt.log"

          TOTAL_TEKTON=$((TOTAL_TEKTON + 1))

          if transform_tekton_files "${owner}" "${repo}" "${alternate_product}" "${alternate_prefix}" "${dest_branch}" "${default_version}" "${version}" "${transform_log_alt}" "${LAST_RELEASE_VERSION:-}"; then
            status=0
          else
            status=$?
          fi

          if [[ $status -ne 0 ]]; then
            exit_code=$((exit_code | status))
            FAILED_TEKTON+=("${owner_repo} (transform ${alternate_product} ${default_version} → ${version} on ${dest_branch})")
            echo "ERROR: Failed to transform ${alternate_product} Tekton files for ${owner_repo}"
            if [[ -f "${transform_log_alt}" ]]; then
              echo "  Last 10 lines of log:"
              tail -10 "${transform_log_alt}" | sed 's/^/    /'
            else
              echo "  ERROR: Log file not found: ${transform_log_alt}"
            fi
          else
            SUCCESSFUL_TEKTON=$((SUCCESSFUL_TEKTON + 1))
            echo "SUCCESS: Transformed ${alternate_product} Tekton files for ${owner_repo} on ${dest_branch}"
          fi
        fi
      done
    fi
  done
done

# Cleanup stale ff-* branches from old PR fallback code
echo ""
echo "=== Cleaning up stale ff-* branches ==="
echo ""

declare -a CLEANED_BRANCHES
TOTAL_CLEANED=0

# Get unique repos we processed
declare -A PROCESSED_REPO_MAP
for product in mce acm globalhub; do
  component_repos=$(yq '.components[] |
      select((.bundle == "'"${product}-operator-bundle"'" or
      .name == "'"${product}-operator-bundle"'") and
      (.repository | test("^https://github\\.com/stolostron/"))).repository' "${REPO_MAP_PATH}" | sort -u)

  for repo in ${component_repos}; do
    owner_repo=${repo#https://github.com/}
    owner=${owner_repo%/*}
    repo_name=${owner_repo#*/}

    # Skip if not stolostron or if in skip lists
    if [[ ! "${owner_repo}" =~ ^stolostron/ ]]; then
      continue
    fi

    skip_repo=false
    for skipped in "${SKIPPED_REPOS[@]}"; do
      if [[ "${repo_name}" == "${skipped}" ]]; then
        skip_repo=true
        break
      fi
    done

    if [[ "${skip_repo}" == "true" ]]; then
      continue
    fi

    # Check if we have access
    if ! can_push_to_repo "${owner}" "${repo_name}"; then
      continue
    fi

    PROCESSED_REPO_MAP["${owner}/${repo_name}"]=1
  done
done

# Export GitHub token for gh CLI
if [[ -f "${GITHUB_TOKEN_FILE}" ]]; then
  token=$(cat "${GITHUB_TOKEN_FILE}")
  export GH_TOKEN="${token}"
fi

# For each processed repo, clean up stale ff-* branches
for owner_repo in "${!PROCESSED_REPO_MAP[@]}"; do
  owner=${owner_repo%/*}
  repo=${owner_repo#*/}

  echo "INFO: Checking ${owner_repo} for stale ff-* branches"

  # Get all ff-* branches for this repo
  if ! command -v gh >/dev/null 2>&1; then
    echo "WARNING: gh CLI not available, skipping cleanup"
    break
  fi

  # List all branches matching ff-release-* or ff-backplane-*
  stale_branches=$(gh api "repos/${owner}/${repo}/branches" --paginate --jq '.[].name | select(test("^ff-(release|backplane)-"))' 2>&1)
  api_status=$?

  if [[ $api_status -ne 0 ]]; then
    echo "WARNING: Failed to list branches for ${owner_repo}: ${stale_branches}"
    continue
  fi

  if [[ -z "${stale_branches}" ]]; then
    continue
  fi

  # Check each branch
  while IFS= read -r branch; do
    [[ -z "${branch}" ]] && continue

    # Check if branch has open PR
    pr_number=$(gh pr list --repo "${owner}/${repo}" --head "${branch}" --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -n "${pr_number}" ]]; then
      # Close the PR first
      echo "INFO: Closing obsolete PR #${pr_number} for ${branch} in ${owner_repo}"
      gh pr close "${pr_number}" --repo "${owner}/${repo}" \
        --comment "Closing obsolete PR. Fast-forward workflow now pushes directly to release branches instead of creating PRs. This branch and PR are no longer needed." \
        2>/dev/null || echo "WARNING: Failed to close PR #${pr_number}"
    fi

    # Delete the branch
    echo "INFO: Deleting stale branch ${branch} from ${owner_repo}"
    if gh api -X DELETE "repos/${owner}/${repo}/git/refs/heads/${branch}" 2>/dev/null; then
      CLEANED_BRANCHES+=("${owner_repo}:${branch}")
      TOTAL_CLEANED=$((TOTAL_CLEANED + 1))
    else
      echo "WARNING: Failed to delete ${branch} from ${owner_repo}"
    fi
  done <<< "${stale_branches}"
done

if [[ ${TOTAL_CLEANED} -gt 0 ]]; then
  echo "INFO: Cleaned ${TOTAL_CLEANED} stale branches"
fi

echo ""
echo "================================================================="
echo "                    FAST-FORWARD WORKFLOW SUMMARY"
echo "================================================================="
echo ""

# Repository summary
echo "Repositories:"
echo "  Total:        ${TOTAL_REPOS}"
echo "  Processed:    ${PROCESSED_REPOS}"
echo "  Skipped:      ${#SKIPPED_NO_ACCESS[@]}"
echo ""

# Fast-forward summary
echo "Fast-Forward Operations:"
echo "  Total:      ${TOTAL_FASTFORWARDS}"
echo "  Successful: ${SUCCESSFUL_FASTFORWARDS}"
echo "  Failed:     $((TOTAL_FASTFORWARDS - SUCCESSFUL_FASTFORWARDS))"
echo ""

# Tekton summary
echo "Tekton File Creation:"
echo "  Total:      ${TOTAL_TEKTON}"
echo "  Successful: ${SUCCESSFUL_TEKTON}"
echo "  Failed:     $((TOTAL_TEKTON - SUCCESSFUL_TEKTON))"
echo ""

# Cleanup summary
echo "Branch Cleanup:"
echo "  Stale ff-* branches deleted: ${TOTAL_CLEANED}"
echo ""

# List skipped repos
if [[ ${#SKIPPED_NO_ACCESS[@]} -gt 0 ]]; then
  echo "Skipped Repositories (No Write Access):"
  for repo in "${SKIPPED_NO_ACCESS[@]+"${SKIPPED_NO_ACCESS[@]}"}"; do
    echo "  - ${repo}"
  done
  echo ""
fi

# List failures if any
if [[ ${#FAILED_FASTFORWARDS[@]} -gt 0 ]]; then
  echo "Failed Fast-Forward Operations:"
  for failure in "${FAILED_FASTFORWARDS[@]+"${FAILED_FASTFORWARDS[@]}"}"; do
    echo "  - ${failure}"
  done
  echo ""
fi

if [[ ${#FAILED_TEKTON[@]} -gt 0 ]]; then
  echo "Failed Tekton File Creations:"
  for failure in "${FAILED_TEKTON[@]+"${FAILED_TEKTON[@]}"}"; do
    echo "  - ${failure}"
  done
  echo ""
fi

# List cleaned branches
if [[ ${#CLEANED_BRANCHES[@]} -gt 0 ]]; then
  echo "Cleaned Stale Branches:"
  for cleaned in "${CLEANED_BRANCHES[@]+"${CLEANED_BRANCHES[@]}"}"; do
    echo "  - ${cleaned}"
  done
  echo ""
fi

if [[ ${exit_code} -eq 0 ]]; then
  echo "================================================================="
  echo "                     ALL OPERATIONS SUCCESSFUL"
  echo "================================================================="
else
  echo "================================================================="
  echo "            WORKFLOW COMPLETED WITH FAILURES (exit ${exit_code})"
  echo "================================================================="
  echo ""
  echo "Check logs in ${ARTIFACT_DIR}/ for details"
fi

echo ""

exit ${exit_code}
