#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPTS_DIR="/opt/ai-helpers/plugins/marketplace-ops/scripts"
REPO="${UPSTREAM_REPO}"
FORK="${FORK_ORG}/ai-helpers"

echo "=== Marketplace Prune Agent ==="
echo "Upstream: ${REPO}"
echo "Fork: ${FORK}"
echo "Model: ${CLAUDE_MODEL}"

# ---------------------------------------------------------------------------
# GitHub App authentication
# ---------------------------------------------------------------------------

set +x
APP_ID=$(cat "${GITHUB_APP_ID_PATH}")
PRIVATE_KEY_FILE="${GITHUB_APP_KEY_PATH}"
INSTALL_ID_FORK=$(cat "${GITHUB_APP_INSTALL_ID_FORK}")
INSTALL_ID_UPSTREAM=$(cat "${GITHUB_APP_INSTALL_ID_UPSTREAM}")

generate_github_token() {
    local INSTALL_ID=$1
    local NOW
    NOW=$(date +%s)
    local IAT=$((NOW - 60))
    local EXP=$((NOW + 600))

    local HEADER
    HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local PAYLOAD
    PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local SIGNATURE
    SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

    curl -s -X POST \
        -H "Authorization: Bearer ${JWT}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
        | jq -r '.token'
}

refresh_tokens() {
    GITHUB_TOKEN_FORK=$(generate_github_token "$INSTALL_ID_FORK")
    git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN_FORK}; }; f"
    GITHUB_TOKEN_UPSTREAM=$(generate_github_token "$INSTALL_ID_UPSTREAM")
    export GITHUB_TOKEN="$GITHUB_TOKEN_UPSTREAM"
}

echo "Generating GitHub App tokens..."
refresh_tokens

if [ -z "$GITHUB_TOKEN_FORK" ] || [ "$GITHUB_TOKEN_FORK" = "null" ]; then
    echo "ERROR: Failed to generate GitHub App token for fork"
    exit 1
fi
if [ -z "$GITHUB_TOKEN_UPSTREAM" ] || [ "$GITHUB_TOKEN_UPSTREAM" = "null" ]; then
    echo "ERROR: Failed to generate GitHub App token for upstream"
    exit 1
fi
echo "GitHub App tokens configured."

# ---------------------------------------------------------------------------
# Clone and set up the repository
# ---------------------------------------------------------------------------

WORKDIR=$(mktemp -d /tmp/marketplace-prune-XXXXXX)
cd "${WORKDIR}"

echo "Cloning ${REPO}..."
gh repo clone "${REPO}" ai-helpers -- --depth=0
cd ai-helpers

git remote rename origin upstream
git remote add origin "https://github.com/${FORK}.git"
git fetch origin || true

git config user.name "openshift-trt-bot"
git config user.email "noreply@github.com"

# ---------------------------------------------------------------------------
# Process existing PR: handle /save and /drop comments
# ---------------------------------------------------------------------------

process_existing_pr() {
    local PR_NUMBER=$1

    # Find the last comment from the bot to determine --since-comment-id
    LAST_BOT_COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
        --jq "[.[] | select(.user.login == \"openshift-trt-bot\" or .user.login | test(\"\\\\[bot\\\\]$\")) | .id] | max // 0")

    echo "Last bot comment ID: ${LAST_BOT_COMMENT_ID}"
    echo "Fetching new comments..."

    COMMENTS_JSON=$(python3 "${SCRIPTS_DIR}/process-comments.py" \
        --repo "${REPO}" \
        --pr-number "${PR_NUMBER}" \
        --since-comment-id "${LAST_BOT_COMMENT_ID}")

    echo "${COMMENTS_JSON}" | jq .

    SAVE_COUNT=$(echo "${COMMENTS_JSON}" | jq '.saves | length')
    DROP_COUNT=$(echo "${COMMENTS_JSON}" | jq '.drops | length')
    ERRORS=$(echo "${COMMENTS_JSON}" | jq -r '.errors[]' 2>/dev/null || true)

    if [ -n "${ERRORS}" ]; then
        echo "Validation errors:"
        echo "${ERRORS}"
    fi

    if [ "${SAVE_COUNT}" -eq 0 ] && [ "${DROP_COUNT}" -eq 0 ]; then
        echo "No new /save or /drop directives found. Nothing to do."
        exit 0
    fi

    echo "Found ${SAVE_COUNT} saves and ${DROP_COUNT} drops."

    # Checkout the PR branch
    gh pr checkout "${PR_NUMBER}"

    BASE_BRANCH=$(gh pr view "${PR_NUMBER}" --json baseRefName --jq '.baseRefName')

    # Process saves
    if [ "${SAVE_COUNT}" -gt 0 ]; then
        SAVE_PATHS=$(echo "${COMMENTS_JSON}" | jq -r '[.saves[].path] | join(",")')
        SAVE_USERS=$(echo "${COMMENTS_JSON}" | jq -r '[.saves[].author] | join(",")')

        echo "Processing saves: ${SAVE_PATHS}"
        python3 "${SCRIPTS_DIR}/apply-changes.py" \
            --action save \
            --paths "${SAVE_PATHS}" \
            --base-branch "${BASE_BRANCH}" \
            --repo-root . \
            --usernames "${SAVE_USERS}"
    fi

    # Process drops
    if [ "${DROP_COUNT}" -gt 0 ]; then
        DROP_PATHS=$(echo "${COMMENTS_JSON}" | jq -r '[.drops[].path] | join(",")')
        DROP_USERS=$(echo "${COMMENTS_JSON}" | jq -r '[.drops[].author] | join(",")')

        echo "Processing drops: ${DROP_PATHS}"
        python3 "${SCRIPTS_DIR}/apply-changes.py" \
            --action drop \
            --paths "${DROP_PATHS}" \
            --repo-root . \
            --usernames "${DROP_USERS}"
    fi

    # Sync marketplace and commit
    make update
    git add -A

    if git diff --cached --quiet; then
        echo "No changes to commit after processing."
        exit 0
    fi

    COMMIT_MSG="chore: process save/drop directives from pruning PR #${PR_NUMBER}"
    if [ "${SAVE_COUNT}" -gt 0 ]; then
        COMMIT_MSG="${COMMIT_MSG}

Saved:
$(echo "${COMMENTS_JSON}" | jq -r '.saves[] | "- \(.path) — by @\(.author)"')"
    fi
    if [ "${DROP_COUNT}" -gt 0 ]; then
        COMMIT_MSG="${COMMIT_MSG}

Dropped:
$(echo "${COMMENTS_JSON}" | jq -r '.drops[] | "- \(.path) — by @\(.author)"')"
    fi

    git commit -m "$(cat <<EOF
${COMMIT_MSG}

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"

    # Refresh tokens before push (may have expired during processing)
    refresh_tokens
    git push

    # Update PR body
    SAVE_PATHS_ARG=""
    SAVE_USERS_ARG=""
    DROP_PATHS_ARG=""
    DROP_USERS_ARG=""

    if [ "${SAVE_COUNT}" -gt 0 ]; then
        SAVE_PATHS_ARG=$(echo "${COMMENTS_JSON}" | jq -r '[.saves[].path] | join(",")')
        SAVE_USERS_ARG=$(echo "${COMMENTS_JSON}" | jq -r '[.saves[].author] | join(",")')
    fi
    if [ "${DROP_COUNT}" -gt 0 ]; then
        DROP_PATHS_ARG=$(echo "${COMMENTS_JSON}" | jq -r '[.drops[].path] | join(",")')
        DROP_USERS_ARG=$(echo "${COMMENTS_JSON}" | jq -r '[.drops[].author] | join(",")')
    fi

    python3 "${SCRIPTS_DIR}/update-pr-body.py" \
        --repo "${REPO}" \
        --pr-number "${PR_NUMBER}" \
        --saves "${SAVE_PATHS_ARG}" \
        --drops "${DROP_PATHS_ARG}" \
        --save-usernames "${SAVE_USERS_ARG}" \
        --drop-usernames "${DROP_USERS_ARG}"

    # Post summary comment
    COMMENT_BODY="Processed \`/save\` and \`/drop\` comments."
    if [ "${SAVE_COUNT}" -gt 0 ]; then
        SAVED_LIST=$(echo "${COMMENTS_JSON}" | jq -r '.saves[] | "- `\(.path)` — saved by @\(.author)"')
        COMMENT_BODY="${COMMENT_BODY}

**Saved** (restored and added to \`.pruneprotect\`):
${SAVED_LIST}"
    fi
    if [ "${DROP_COUNT}" -gt 0 ]; then
        DROPPED_LIST=$(echo "${COMMENTS_JSON}" | jq -r '.drops[] | "- `\(.path)` — dropped by @\(.author)"')
        COMMENT_BODY="${COMMENT_BODY}

**Dropped** (removed):
${DROPPED_LIST}"
    fi

    gh pr comment "${PR_NUMBER}" --repo "${REPO}" --body "${COMMENT_BODY}"
    echo "PR #${PR_NUMBER} updated successfully."
}

# ---------------------------------------------------------------------------
# Create new prune PR
# ---------------------------------------------------------------------------

create_new_pr() {
    BRANCH_NAME="prune/$(date +%Y%m%d)"

    # Step 1: Plugin-level scoring (fully deterministic)
    echo "=== Step 1: Scoring plugins ==="
    PLUGIN_REPORT="/tmp/plugin-report.json"
    python3 "${SCRIPTS_DIR}/score-plugins.py" . > "${PLUGIN_REPORT}"

    CANDIDATE_COUNT=$(jq '.summary.candidates' "${PLUGIN_REPORT}")
    echo "Plugin candidates for removal: ${CANDIDATE_COUNT}"

    # Create the working branch
    git checkout -b "${BRANCH_NAME}" upstream/main

    # Step 2: Remove plugin-level candidates (deterministic)
    echo "=== Step 2: Removing plugin candidates ==="
    REMOVED_PLUGINS=()
    while IFS= read -r path; do
        [ -z "${path}" ] && continue
        echo "Removing plugin: ${path}"
        git rm -rf "${path}"
        REMOVED_PLUGINS+=("${path}")
    done < <(jq -r '.candidates[].path' "${PLUGIN_REPORT}")

    # Build list of surviving non-protected plugin names for item scoring
    SURVIVING_PLUGINS=$(jq -r '.safe[].name' "${PLUGIN_REPORT}" | tr '\n' ',' | sed 's/,$//')

    # Step 3: Item-level scoring (deterministic)
    echo "=== Step 3: Scoring individual items ==="
    ITEM_REPORT="/tmp/item-report.json"
    if [ -n "${SURVIVING_PLUGINS}" ]; then
        python3 "${SCRIPTS_DIR}/score-items.py" --plugins "${SURVIVING_PLUGINS}" . > "${ITEM_REPORT}"
    else
        python3 "${SCRIPTS_DIR}/score-items.py" . > "${ITEM_REPORT}"
    fi

    FLAGGED_COUNT=$(jq '.summary.flagged' "${ITEM_REPORT}")
    echo "Flagged items for LLM review: ${FLAGGED_COUNT}"

    # Step 4: LLM review of flagged items (only part using Claude)
    ITEM_REMOVALS="/tmp/item-removals.json"
    if [ "${FLAGGED_COUNT}" -gt 0 ]; then
        echo "=== Step 4: Invoking Claude for item-level review ==="

        # Workaround: see openshift-claude-payload-agent-commands.sh
        export CLAUDE_CODE_ENTRYPOINT=sdk-cli

        claude \
            --model "${CLAUDE_MODEL}" \
            --allowedTools "Bash Read Grep Glob" \
            --output-format text \
            --max-turns 30 \
            -p "Review the flagged items in ${ITEM_REPORT} using the marketplace-ops prune skill. Output ONLY a JSON array of objects with keys: path, action (remove or keep), reason. The flagged items file is at: ${ITEM_REPORT}" \
            --verbose 2>&1 | tee "${ARTIFACT_DIR:-/tmp}/claude-prune-output.log"

        # Extract JSON array from Claude's text output
        grep -Pzo '(?s)\[.*\]' "${ARTIFACT_DIR:-/tmp}/claude-prune-output.log" \
            | head -c 1048576 > "${ITEM_REMOVALS}" || true

        if [ ! -s "${ITEM_REMOVALS}" ] || ! jq empty "${ITEM_REMOVALS}" 2>/dev/null; then
            echo "Warning: Could not parse Claude output as JSON. Using empty removals."
            echo "[]" > "${ITEM_REMOVALS}"
        fi
    else
        echo "No flagged items. Skipping LLM review."
        echo "[]" > "${ITEM_REMOVALS}"
    fi

    ITEM_REMOVAL_COUNT=$(jq '[.[] | select(.action == "remove")] | length' "${ITEM_REMOVALS}")
    echo "Items to remove after LLM review: ${ITEM_REMOVAL_COUNT}"

    # Step 5: Remove items flagged by LLM (deterministic)
    echo "=== Step 5: Removing flagged items ==="
    AFFECTED_PLUGINS=()
    while IFS= read -r path; do
        [ -z "${path}" ] && continue
        echo "Removing item: ${path}"
        if [ -d "${path}" ]; then
            git rm -rf "${path}"
        elif [ -f "${path}" ]; then
            git rm "${path}"
        fi
        plugin=$(echo "${path}" | cut -d'/' -f2)
        AFFECTED_PLUGINS+=("${plugin}")
    done < <(jq -r '.[] | select(.action == "remove") | .path' "${ITEM_REMOVALS}")

    # Step 6: Cross-reference scan (deterministic)
    echo "=== Step 6: Cross-reference scan ==="
    XREF_REPORT="/tmp/cross-refs.json"
    ALL_REMOVALS=""
    for p in "${REMOVED_PLUGINS[@]+"${REMOVED_PLUGINS[@]}"}"; do
        ALL_REMOVALS="${ALL_REMOVALS:+${ALL_REMOVALS},}${p}"
    done
    while IFS= read -r path; do
        [ -z "${path}" ] && continue
        ALL_REMOVALS="${ALL_REMOVALS:+${ALL_REMOVALS},}${path}"
    done < <(jq -r '.[] | select(.action == "remove") | .path' "${ITEM_REMOVALS}")

    if [ -n "${ALL_REMOVALS}" ]; then
        python3 "${SCRIPTS_DIR}/cross-reference-scan.py" \
            --removals "${ALL_REMOVALS}" \
            --repo-root . > "${XREF_REPORT}"
        XREF_COUNT=$(jq '.warnings | length' "${XREF_REPORT}")
        echo "Cross-reference warnings: ${XREF_COUNT}"
    else
        echo '{"warnings": []}' > "${XREF_REPORT}"
        echo "No removals to cross-reference."
    fi

    # Step 7: Bump versions for affected plugins (deterministic)
    echo "=== Step 7: Bumping versions ==="
    declare -A BUMPED=()
    for plugin in "${AFFECTED_PLUGINS[@]+"${AFFECTED_PLUGINS[@]}"}"; do
        if [ -z "${BUMPED[${plugin}]+x}" ]; then
            PJ="plugins/${plugin}/.claude-plugin/plugin.json"
            if [ -f "${PJ}" ]; then
                OLD_VER=$(jq -r '.version' "${PJ}")
                python3 -c "
import json
with open('${PJ}') as f: d = json.load(f)
v = d['version'].split('.')
v[2] = str(int(v[2]) + 1)
d['version'] = '.'.join(v)
with open('${PJ}', 'w') as f: json.dump(d, f, indent=2); f.write('\n')
"
                NEW_VER=$(jq -r '.version' "${PJ}")
                echo "Bumped ${plugin}: ${OLD_VER} -> ${NEW_VER}"
                BUMPED[${plugin}]=1
            fi
        fi
    done

    # Step 8: Sync and commit (deterministic)
    echo "=== Step 8: Syncing and committing ==="
    make update
    git add -A

    if git diff --cached --quiet; then
        echo "No changes to commit. Nothing to prune."
        exit 0
    fi

    git commit -m "$(cat <<'EOF'
chore: prune stale plugins, commands, and skills

See PR description for full removal manifest.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"

    # Step 9: Push to fork
    echo "=== Step 9: Pushing to fork ==="
    refresh_tokens
    git push -u origin "${BRANCH_NAME}"

    # Step 10: Build PR body and create PR
    echo "=== Step 10: Creating PR ==="
    ITEM_REMOVALS_WITH_TYPE="/tmp/item-removals-typed.json"
    jq '[.[] | select(.action == "remove") | {path, reason, type: (if (.path | test("/skills/")) then "skill" elif (.path | test("/commands/")) then "command" else "item" end)}]' \
        "${ITEM_REMOVALS}" > "${ITEM_REMOVALS_WITH_TYPE}"

    PR_BODY=$(python3 "${SCRIPTS_DIR}/build-pr-body.py" \
        --plugin-report "${PLUGIN_REPORT}" \
        --item-removals "${ITEM_REMOVALS_WITH_TYPE}" \
        --cross-refs "${XREF_REPORT}")

    PR_URL=$(gh pr create \
        --repo "${REPO}" \
        --head "${FORK_ORG}:${BRANCH_NAME}" \
        --title "chore: prune stale marketplace content" \
        --body "${PR_BODY}")

    echo ""
    echo "=== Prune PR created ==="
    echo "URL: ${PR_URL}"
    echo "Plugin removals: ${CANDIDATE_COUNT}"
    echo "Item removals: ${ITEM_REMOVAL_COUNT}"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

echo "Checking for existing prune PR..."
EXISTING_PR=$(gh pr list \
    --repo "${REPO}" \
    --state open \
    --search "prune stale marketplace" \
    --json number,headRefName \
    --limit 1 \
    --jq '.[0] // empty')

if [ -n "${EXISTING_PR}" ]; then
    PR_NUMBER=$(echo "${EXISTING_PR}" | jq -r '.number')
    PR_BRANCH=$(echo "${EXISTING_PR}" | jq -r '.headRefName')
    echo "Found existing prune PR #${PR_NUMBER} on branch ${PR_BRANCH}"
    process_existing_pr "${PR_NUMBER}"
else
    echo "No existing prune PR found. Creating new one."
    create_new_pr
fi
