#!/bin/bash
set -euo pipefail
export GOTOOLCHAIN=auto

echo "=== Rosa Regional Platform Documentation Update Process ==="

# Generate GitHub App installation token
echo "Generating GitHub App token..."

GITHUB_APP_CREDS_DIR="/var/run/claude-code-service-account"
APP_ID_FILE="${GITHUB_APP_CREDS_DIR}/app-id"
INSTALLATION_ID_FILE="${GITHUB_APP_CREDS_DIR}/installation-id"
PRIVATE_KEY_FILE="${GITHUB_APP_CREDS_DIR}/private-key"
INSTALLATION_ID_UPSTREAM_FILE="${GITHUB_APP_CREDS_DIR}/o-o-installation-id"

# Check if all required credentials exist
if [ ! -f "$APP_ID_FILE" ] || [ ! -f "$INSTALLATION_ID_FILE" ] || [ ! -f "$PRIVATE_KEY_FILE" ] || [ ! -f "$INSTALLATION_ID_UPSTREAM_FILE" ]; then
  echo "GitHub App credentials not yet available in ${GITHUB_APP_CREDS_DIR}"
  echo "Available files:"
  ls -la "${GITHUB_APP_CREDS_DIR}/" || echo "Directory does not exist"
  echo ""
  echo "Waiting for Vault secretsync to complete. The following keys are required:"
  echo "  - app-id"
  echo "  - installation-id (for fork)"
  echo "  - o-o-installation-id (for openshift-online/rosa-regional-platform upstream)"
  echo "  - private-key"
  echo ""
  echo "Exiting gracefully. Re-run once secrets are synced."
  exit 0
fi

APP_ID=$(cat "$APP_ID_FILE")
INSTALLATION_ID_FORK=$(cat "$INSTALLATION_ID_FILE")
INSTALLATION_ID_UPSTREAM=$(cat "$INSTALLATION_ID_UPSTREAM_FILE")

# Function to generate GitHub App token for a given installation ID
generate_github_token() {
  local INSTALL_ID=$1
  local NOW
  local IAT
  local EXP
  local HEADER
  local PAYLOAD
  local SIGNATURE
  local JWT

  NOW=$(date +%s)
  IAT=$((NOW - 60))
  EXP=$((NOW + 600))

  HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

  curl -s -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
    | jq -r '.token'
}

# Generate token for fork - for pushing branches
echo "Generating GitHub App token for fork..."
GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALLATION_ID_FORK")
if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
  echo "ERROR: Failed to generate GitHub App token for fork"
  exit 1
fi
echo "Fork token generated successfully"

# Generate token for upstream - for creating PRs and closing stale PRs
echo "Generating GitHub App token for upstream..."
GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")
if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
  echo "ERROR: Failed to generate GitHub App token for upstream"
  exit 1
fi
echo "Upstream token generated successfully"

# Clone rosa-regional-platform repository from fork
echo "Cloning rosa-regional-platform repository..."
mkdir -p /tmp/doc-update
cd /tmp/doc-update

# Fork organization pattern (similar to hypershift-community for HyperShift)
# rosa-regional-platform-ci organization hosts forks for CI automation
FORK_OWNER="rosa-regional-platform-ci"
UPSTREAM_OWNER="openshift-online"

# Define rosa-regional-platform repositories
# rosa-regional-platform-internal is only included if INCLUDE_INTERNAL_REPO is set to "true"
# since it's a private repository that may not be accessible from public Prow CI
REPOS=(
  "rosa-regional-platform"
  "rosa-regional-platform-api"
  "rosa-regional-platform-cli"
)

if [ "${INCLUDE_INTERNAL_REPO:-false}" = "true" ]; then
  echo "Including rosa-regional-platform-internal repository (INCLUDE_INTERNAL_REPO=true)"
  REPOS+=("rosa-regional-platform-internal")
else
  echo "Excluding rosa-regional-platform-internal repository (INCLUDE_INTERNAL_REPO=${INCLUDE_INTERNAL_REPO:-false})"
  echo "Note: rosa-regional-platform-internal is a private repository not accessible from public Prow CI"
fi

echo "Repositories to process: ${REPOS[*]}"

# Configure git globally
echo "Configuring git..."
git config --global user.name "ROSA Regional Platform Bot"
git config --global user.email "rosa-regional-platform-bot@redhat.com"

# Configure git to use the fork token for push operations via credential helper
# Using credential helper instead of URL rewriting prevents token leaking in git remote output
git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"

# Configure gh CLI with upstream token for PR operations
export GH_TOKEN="${GITHUB_TOKEN_UPSTREAM}"

echo "Cloning rosa-regional-platform repositories..."
SUCCESSFULLY_CLONED_REPOS=()

for REPO_NAME in "${REPOS[@]}"; do
  echo "Cloning ${REPO_NAME}..."

  # Try fork first, then upstream
  if git clone "https://github.com/${FORK_OWNER}/${REPO_NAME}" "${REPO_NAME}" 2>/dev/null; then
    echo "  Cloned from fork: ${FORK_OWNER}/${REPO_NAME}"
    CLONED_FROM_FORK=true
  elif git clone "https://github.com/${UPSTREAM_OWNER}/${REPO_NAME}" "${REPO_NAME}" 2>/dev/null; then
    echo "  Cloned from upstream: ${UPSTREAM_OWNER}/${REPO_NAME}"
    CLONED_FROM_FORK=false
  else
    echo "  ERROR: Failed to clone ${REPO_NAME} from both fork and upstream"
    echo "  This repository will be skipped in the analysis"
    continue
  fi

  cd "${REPO_NAME}"

  # Add upstream remote if cloned from fork
  if [ "${CLONED_FROM_FORK}" = true ]; then
    echo "  Adding upstream remote for ${REPO_NAME}..."
    git remote add upstream "https://github.com/${UPSTREAM_OWNER}/${REPO_NAME}.git" 2>/dev/null || true
  else
    # Cloned from upstream, add origin as fork
    echo "  Setting up fork remote for ${REPO_NAME}..."
    git remote rename origin upstream 2>/dev/null || true
    git remote add origin "https://github.com/${FORK_OWNER}/${REPO_NAME}.git" 2>/dev/null || true
  fi

  git fetch --all 2>/dev/null || echo "  WARNING: Failed to fetch all remotes for ${REPO_NAME}"
  cd ..

  SUCCESSFULLY_CLONED_REPOS+=("${REPO_NAME}")
done

if [ ${#SUCCESSFULLY_CLONED_REPOS[@]} -eq 0 ]; then
  echo "ERROR: Failed to clone any repositories"
  exit 1
fi

echo "Successfully cloned ${#SUCCESSFULLY_CLONED_REPOS[@]} repositories: ${SUCCESSFULLY_CLONED_REPOS[*]}"

# Update REPOS array to only include successfully cloned repositories
REPOS=("${SUCCESSFULLY_CLONED_REPOS[@]}")

# Step 1: Auto-Close Stale PRs
echo ""
echo "=== Step 1: Auto-Closing Stale Documentation PRs ==="

# Get bot username
GH_USER=$(gh api user --jq .login)
echo "Bot username: ${GH_USER}"

# Calculate cutoff date for stale PRs
STALE_CUTOFF=$(date -u -d "${STALE_PR_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-${STALE_PR_DAYS}d +%Y-%m-%dT%H:%M:%SZ)
echo "Closing PRs created before: ${STALE_CUTOFF}"

# Check all repositories for stale PRs
TOTAL_CLOSED=0
for REPO_NAME in "${REPOS[@]}"; do
  echo "Checking ${REPO_NAME} for stale PRs..."

  # List own open PRs with [docs-agent] prefix
  STALE_PRS=$(gh pr list \
    --repo "${UPSTREAM_OWNER}/${REPO_NAME}" \
    --author "${GH_USER}" \
    --state open \
    --search "[docs-agent]" \
    --json number,title,createdAt \
    --jq ".[] | select(.createdAt < \"${STALE_CUTOFF}\") | .number")

  if [ -n "$STALE_PRS" ]; then
    echo "Found stale PRs in ${REPO_NAME}:"
    for PR_NUM in $STALE_PRS; do
      echo "  - PR #${PR_NUM}"
      gh pr close "${PR_NUM}" \
        --repo "${UPSTREAM_OWNER}/${REPO_NAME}" \
        --comment "Auto-closing: this documentation update was not reviewed within ${STALE_PR_DAYS} days. If the changes are still relevant, a new PR will be opened in a future run." || true
      TOTAL_CLOSED=$((TOTAL_CLOSED + 1))
    done
  fi
done

echo "Total stale PRs closed across all repos: ${TOTAL_CLOSED}"

# Step 2: Identify Recent Merged PRs
echo ""
echo "=== Step 2: Identifying Recently Merged PRs ==="

LOOKBACK_DATE=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-${LOOKBACK_HOURS}H +%Y-%m-%dT%H:%M:%SZ)
echo "Looking for PRs merged since: ${LOOKBACK_DATE}"

# Collect merged PRs from all repositories
declare -A REPO_MERGED_PRS
TOTAL_PR_COUNT=0

for REPO_NAME in "${REPOS[@]}"; do
  echo "Checking ${REPO_NAME} for merged PRs..."

  # Get merged PRs excluding bot's own PRs
  MERGED_PRS=$(gh pr list \
    --repo "${UPSTREAM_OWNER}/${REPO_NAME}" \
    --state merged \
    --search "merged:>=${LOOKBACK_DATE}" \
    --limit 50 \
    --json number,title,author \
    --jq "[.[] | select(.author.login != \"${GH_USER}\")] | map(.number) | join(\",\")")

  if [ -n "$MERGED_PRS" ] && [ "$MERGED_PRS" != "null" ]; then
    REPO_MERGED_PRS["${REPO_NAME}"]="${MERGED_PRS}"
    REPO_PR_COUNT=$(echo "$MERGED_PRS" | tr ',' '\n' | wc -l)
    echo "  Found ${REPO_PR_COUNT} merged PRs in ${REPO_NAME}"
    TOTAL_PR_COUNT=$((TOTAL_PR_COUNT + REPO_PR_COUNT))
  else
    echo "  No merged PRs in ${REPO_NAME}"
  fi
done

if [ "${TOTAL_PR_COUNT}" -eq 0 ]; then
  echo "No merged PRs found across any repository in the lookback window. Nothing to do."
  echo "Exiting gracefully."

  # Save result to SHARED_DIR
  cat > "${SHARED_DIR:-/tmp}/claude-output.json" <<EOF
{
  "updates_needed": false,
  "analyzed_prs": 0,
  "stale_docs": [],
  "branch_created": null,
  "pr_created": null,
  "errors": [],
  "reason": "No merged PRs found in lookback window across all repositories"
}
EOF
  exit 0
fi

echo "Total PRs to analyze across all repos: ${TOTAL_PR_COUNT}"

# Step 3: Sync all forks with upstream before creating branches
echo ""
echo "=== Step 3: Syncing all forks with upstream ==="

for REPO_NAME in "${REPOS[@]}"; do
  if [ -d "${REPO_NAME}" ]; then
    echo "Syncing ${REPO_NAME}..."
    cd "${REPO_NAME}"
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || {
      echo "WARNING: Could not checkout main/master for ${REPO_NAME}"
      cd ..
      continue
    }
    git fetch upstream || git fetch origin
    git reset --hard upstream/main 2>/dev/null || git reset --hard upstream/master 2>/dev/null || git reset --hard origin/main 2>/dev/null || git reset --hard origin/master
    git push origin HEAD --force 2>/dev/null || echo "WARNING: Failed to push to fork for ${REPO_NAME}, continuing anyway"
    cd ..
  fi
done

# Step 4: Invoke Claude for Documentation Analysis
echo ""
echo "=== Step 4: Invoking Claude for Documentation Analysis ==="

# Build the list of merged PRs for the prompt (organized by repository)
MERGED_PRS_LIST=""
for REPO_NAME in "${REPOS[@]}"; do
  if [ -n "${REPO_MERGED_PRS[${REPO_NAME}]:-}" ]; then
    MERGED_PRS_LIST+="
**Repository: ${REPO_NAME}**
"
    echo "${REPO_MERGED_PRS[${REPO_NAME}]}" | tr ',' '\n' | sed "s/^/- ${REPO_NAME}#/"
    MERGED_PRS_LIST+=$(echo "${REPO_MERGED_PRS[${REPO_NAME}]}" | tr ',' '\n' | sed "s/^/- ${REPO_NAME}#/")
    MERGED_PRS_LIST+="
"
  fi
done

# Create a temporary file for the Claude prompt
# Build repository list for Claude prompt
REPO_LIST=""
REPO_COUNT=0
for REPO_NAME in "${REPOS[@]}"; do
  REPO_COUNT=$((REPO_COUNT + 1))
  case "${REPO_NAME}" in
    "rosa-regional-platform")
      REPO_LIST+="${REPO_COUNT}. rosa-regional-platform (main platform repository with architecture docs)
"
      ;;
    "rosa-regional-platform-api")
      REPO_LIST+="${REPO_COUNT}. rosa-regional-platform-api (API server)
"
      ;;
    "rosa-regional-platform-cli")
      REPO_LIST+="${REPO_COUNT}. rosa-regional-platform-cli (CLI tool)
"
      ;;
    "rosa-regional-platform-internal")
      REPO_LIST+="${REPO_COUNT}. rosa-regional-platform-internal (internal tooling and infrastructure)
"
      ;;
  esac
done

CLAUDE_PROMPT=$(cat <<EOF
You are the documentation-updater agent for the ROSA Regional Platform. Your job is to analyze recently merged PRs across rosa-regional-platform repositories and update stale documentation.

## Context

The ROSA Regional Platform repositories being analyzed in this run:
${REPO_LIST}

The following PRs were merged in the last ${LOOKBACK_HOURS} hours (${TOTAL_PR_COUNT} total PRs across all repos):

${MERGED_PRS_LIST}

## Your Task

You are currently in /tmp/doc-update with all four repositories cloned:
- rosa-regional-platform/
- rosa-regional-platform-api/
- rosa-regional-platform-cli/
- rosa-regional-platform-internal/

Follow the procedure defined in .claude/agents/documentation-updater.md:

### Phase 1: Analyze Each Merged PR

For each PR listed above:
1. Identify the repository from the PR reference (e.g., "rosa-regional-platform#123")
2. Fetch the PR diff using: gh pr diff <number> --repo ${UPSTREAM_OWNER}/<repository-name>
3. Read the changes and understand what was modified
4. Check if changes affect documentation in ANY of the four repositories:
   - Changes in rosa-regional-platform-api might affect docs in rosa-regional-platform
   - Changes in rosa-regional-platform-cli might affect docs in rosa-regional-platform
   - Cross-repository impacts are common (e.g., API changes need platform docs updated)
5. Track all documentation that needs updates (including which repository the docs are in)

### Phase 2: Determine if Updates Needed

After analyzing all PRs:
- If NO documentation updates are needed in ANY repository: output JSON {"updates_needed": false, "reason": "..."} and exit
- If documentation updates ARE needed in ANY repository: proceed to Phase 3

### Phase 3: Create Documentation Updates (Per Repository)

For EACH repository that needs doc updates:
1. cd into the repository directory
2. Create a new branch: docs/update-<area>-\$(date +%Y-%m-%d)
3. Update the stale documentation files following these rules:
   - Only update EXISTING documentation (never create new files)
   - Use Mermaid for diagrams (never ASCII art)
   - Follow prettier formatting for markdown
   - Design over implementation approach
   - Match existing documentation style
4. If the repository has a Makefile with pre-push target, run "make pre-push" to validate
5. Commit changes with a descriptive message
6. Push branch to fork (origin)
7. Return to /tmp/doc-update

### Phase 4: Open Pull Requests (One Per Repository)

For each repository with updates:
- cd into the repository
- Create a PR with:
  - Title: "[docs-agent] Update <area> documentation"
  - Body should include:
    - Summary of what was updated and why
    - List of PRs that triggered the update (with repo#PR format, e.g., rosa-regional-platform-api#45)
    - /cc mentions for relevant PR authors
    - Note if updates were triggered by changes in a different repository
  - Use: gh pr create --repo ${UPSTREAM_OWNER}/<repository-name> --head ${FORK_OWNER}:<branch> --base main --title "..." --body "..."
- Return to /tmp/doc-update

### Phase 5: Output Results

Output JSON with:
{
  "updates_needed": true/false,
  "analyzed_prs": <count>,
  "repositories_updated": ["repo1", "repo2", ...],
  "prs_created": [
    {"repo": "rosa-regional-platform", "number": 123, "url": "...", "title": "..."},
    {"repo": "rosa-regional-platform-api", "number": 45, "url": "...", "title": "..."}
  ],
  "stale_docs": {
    "rosa-regional-platform": ["docs/file1.md", "docs/file2.md"],
    "rosa-regional-platform-api": ["docs/api.md"]
  },
  "errors": ["..."] or []
}

## Important Guidelines

- Use tools: Bash, Read, Edit, Write, Grep, Glob (NO Agent tool, NO Task tool)
- Always use cd to navigate between repositories
- Be thorough in cross-repository analysis (changes in -api or -cli often affect -platform docs)
- Only update docs that are actually stale
- Exit gracefully if no updates needed (not an error)
- Track all errors but don't fail the job
- When running gh pr create, you must provide --head ${FORK_OWNER}:<branch-name>
- Handle each repository independently - if one fails, continue with others
EOF
)

# Save output to shared dir for reporting
OUTPUT_FILE="${SHARED_DIR:-/tmp}/claude-output.json"

# Invoke Claude
echo "Invoking Claude with documentation-updater agent..."

# Disable tracing for Claude invocation to avoid token leakage
set +x
claude \
  --allowedTools "Bash,Read,Edit,Write,Grep,Glob" \
  --maxTurns 100 \
  --output-format json \
  --model "${CLAUDE_MODEL}" \
  --prompt "${CLAUDE_PROMPT}" \
  > "${OUTPUT_FILE}" 2>&1 || {
    echo "ERROR: Claude invocation failed"
    echo "Output saved to: ${OUTPUT_FILE}"
    cat "${OUTPUT_FILE}" || true
    exit 1
  }
set -x

echo "Claude processing complete"
echo "Output saved to: ${OUTPUT_FILE}"

# Parse results
UPDATES_NEEDED=$(jq -r '.updates_needed // false' "${OUTPUT_FILE}")
REPOS_UPDATED=$(jq -r '.repositories_updated // []' "${OUTPUT_FILE}")
PRS_CREATED=$(jq -r '.prs_created // []' "${OUTPUT_FILE}")

if [ "$UPDATES_NEEDED" = "true" ]; then
  echo ""
  echo "=== Documentation updates created ==="
  echo "Repositories updated: $(echo "${REPOS_UPDATED}" | jq -r 'join(", ")')"
  echo "PRs created:"
  echo "${PRS_CREATED}" | jq -r '.[] | "  - \(.repo)#\(.number): \(.url)"'
  echo ""
  echo "Full results:"
  jq '.' "${OUTPUT_FILE}"
else
  echo ""
  echo "=== No documentation updates needed ==="
  echo "All documentation is up to date across all repositories"
fi

echo ""
echo "=== Process complete ==="
