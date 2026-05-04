#!/bin/bash
set -euo pipefail

# =============================================================================
# RHDH Plugin Export Overlays - E2E Test Runner (OpenShift CI)
#
# Job modes (nightly / pr-check) determine:
#   - Whether GIT_PR_NUMBER is exported (controls PR vs released OCI image resolution)
#   - Which workspaces to test (all vs changed)
#
# Job flows:
#
#   Scenario                                | JOB_TYPE  | JOB_NAME         | Mode     | GIT_PR_NUMBER | Code tested | OCI images | Tests
#   ----------------------------------------|-----------|------------------|----------|---------------|-------------|------------|------
#   Overlay PR (pr-check)                   | presubmit | pull-ci-*        | pr-check | PR number     | PR branch   | PR-built   | changed workspace
#   Overlay PR (nightly)                    | presubmit | pull-ci-*nightly | nightly  | not exported  | PR branch   | released   | all workspaces
#   Rehearse pr-check                       | presubmit | rehearse-*       | pr-check | empty         | main        | —          | skips (no changes)
#   Rehearse pr-check + REHEARSE_PR_NUMBER  | presubmit | rehearse-*       | pr-check | REHEARSE_PR   | PR branch   | PR-built   | changed workspace
#   Rehearse nightly                        | presubmit | rehearse-*night  | nightly  | not exported  | main        | released   | all workspaces
#   Rehearse nightly  + REHEARSE_PR_NUMBER  | presubmit | rehearse-*night  | nightly  | not exported  | PR branch   | released   | all workspaces
#   Periodic cron                           | periodic  | periodic-*       | nightly  | not exported  | main        | released   | all workspaces
#
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh-plugin-export-overlays"
OVERLAY_BRANCH=""
REHEARSE_PR_NUMBER=""  # Set overlay repo PR number for rehearse testing

# ── Environment ──────────────────────────────────────────────────────────────

export HOME=/tmp
export CI=true
cd /tmp

# Load VAULT_ secrets
for file in /tmp/secrets/*; do
    [[ -f "$file" ]] || continue
    filename=$(basename "$file")
    [[ "$filename" == *"secretsync-vault-source-path"* ]] && continue
    [[ "$filename" == VAULT_* ]] || continue
    export "$filename"="$(cat "$file")"
done

# ── Parse job spec & determine mode ──────────────────────────────────────────

RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')

# Determine job mode
if [[ "$JOB_TYPE" == "periodic" ]] || [[ "$JOB_NAME" == *nightly* ]]; then
    JOB_MODE="nightly"
else
    JOB_MODE="pr-check"
fi

# Parse PR number for presubmit jobs (needed for checkout)
# Rehearse jobs get PR number from release repo (not overlay), so use REHEARSE_PR_NUMBER override
GIT_PR_NUMBER=""
if [[ "$JOB_TYPE" == "presubmit" ]]; then
    if [[ "$JOB_NAME" == rehearse-* ]]; then
        GIT_PR_NUMBER="${REHEARSE_PR_NUMBER:-}"
    else
        GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number // empty')
    fi
fi

# Only export GIT_PR_NUMBER in pr-check mode (nightly uses released OCI images)
if [[ "$JOB_MODE" == "pr-check" ]]; then
    export GIT_PR_NUMBER
fi

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME RELEASE_BRANCH_NAME JOB_MODE
echo "Repository: ${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}"
echo "Branch: ${RELEASE_BRANCH_NAME}, Mode: ${JOB_MODE}, PR: ${GIT_PR_NUMBER:-none}"

# ── Cluster authentication ───────────────────────────────────────────────────

export OPENSHIFT_API OPENSHIFT_USERNAME OPENSHIFT_PASSWORD
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' "$KUBECONFIG")"
OPENSHIFT_USERNAME="kubeadmin"

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' "$KUBECONFIG"

if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat "$KUBEADMIN_PASSWORD_FILE")"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    OPENSHIFT_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
else
    echo "ERROR: Kubeadmin password file not found"
    exit 1
fi

if ! timeout --foreground 5m bash -c '
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
        sleep 20
    done
'; then
    echo "ERROR: Timed out waiting for cluster login"
    exit 1
fi

# ── Service account & platform info ──────────────────────────────────────────

export K8S_CLUSTER_URL K8S_CLUSTER_TOKEN
K8S_CLUSTER_URL=$(oc whoami --show-server)
oc create serviceaccount tester-sa-2 -n default
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2
K8S_CLUSTER_TOKEN=$(oc create token tester-sa-2 -n default --duration=4h)

export IS_OPENSHIFT="true"
export CONTAINER_PLATFORM="ocp"
export CONTAINER_PLATFORM_VERSION
CONTAINER_PLATFORM_VERSION=$(oc version --output json 2>/dev/null | jq -r '.openshiftVersion' | cut -d'.' -f1,2 || echo "unknown")
echo "Platform: ${CONTAINER_PLATFORM} ${CONTAINER_PLATFORM_VERSION}"

# ── Clone & checkout ─────────────────────────────────────────────────────────

git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}"
git checkout "${OVERLAY_BRANCH:-$RELEASE_BRANCH_NAME}"
git config --global user.name "rhdh-qe"
git config --global user.email "rhdh-qe@redhat.com"

# Checkout PR branch for presubmit jobs
# Rehearse jobs only checkout if REHEARSE_PR_NUMBER is explicitly set (JOB_SPEC PR is from the release repo)
if [[ "$JOB_TYPE" == "presubmit" ]] && [[ -n "$GIT_PR_NUMBER" ]] && { [[ "$JOB_NAME" != rehearse-* ]] || [[ -n "${REHEARSE_PR_NUMBER:-}" ]]; }; then
    git fetch origin "pull/${GIT_PR_NUMBER}/head:PR${GIT_PR_NUMBER}"
    git checkout "PR${GIT_PR_NUMBER}"
    git merge "origin/${RELEASE_BRANCH_NAME}" --no-edit
fi

# ── RHDH version ─────────────────────────────────────────────────────────────

export RHDH_VERSION INSTALLATION_METHOD
if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
    RHDH_VERSION="$(echo "$RELEASE_BRANCH_NAME" | cut -d'-' -f2)"
else
    RHDH_VERSION="1.10" # TODO: Change to "next" when RHIDP-12071 is fixed
fi
INSTALLATION_METHOD="helm"
echo "RHDH_VERSION: ${RHDH_VERSION}, INSTALLATION_METHOD: ${INSTALLATION_METHOD}"

# ── Artifact collection ──────────────────────────────────────────────────────

collect_artifacts() {
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        echo "[INFO] Copying artifacts to ${ARTIFACT_DIR}"
        cp -a playwright-report "${ARTIFACT_DIR}/" 2>&1 || echo "[WARNING] playwright-report not found"
        cp -a node_modules/.cache/e2e-test-results "${ARTIFACT_DIR}/" 2>&1 || echo "[WARNING] e2e-test-results not found"
    fi
}

# ── Post GitHub comment ──────────────────────────────────────────────────────

post_github_comment() {
    set +ex
    local heading="$1"

    [[ -z "${GIT_PR_NUMBER:-}" ]] && return 0
    [[ -z "${VAULT_GITHUB_TEST_REPORTER_TOKEN:-}" ]] && { echo "WARNING: VAULT_GITHUB_TEST_REPORTER_TOKEN not set"; return 1; }

    local gcs_base="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull"
    local test_name="${JOB_NAME##*-"${RELEASE_BRANCH_NAME}"-}"
    local step_path="${gcs_base}/${GITHUB_ORG_NAME}_${GITHUB_REPOSITORY_NAME}/${GIT_PR_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/${test_name}/redhat-developer-rhdh-plugin-export-overlays-ocp-helm"

    local stats counts status comment
    stats=$(jq -r '(.stats.duration // 0) / 1000 | floor | "\(. / 60 | floor)m \(. % 60)s"' playwright-report/results.json 2>/dev/null || echo "N/A")
    counts=$(jq -r '"Passed: \(.stats.expected // 0) | Failed: \(.stats.unexpected // 0) | Flaky: \(.stats.flaky // 0) | Skipped: \(.stats.skipped // 0)"' playwright-report/results.json 2>/dev/null || echo "N/A")
    [[ "$TEST_EXIT_CODE" -eq 0 ]] && status="✅ Passed" || status="❌ Failed"

    comment="### ${status} ${heading}
**Platform:** ${CONTAINER_PLATFORM} ${CONTAINER_PLATFORM_VERSION} | **RHDH Version:** ${RHDH_VERSION} | **Duration:** ${stats}
${counts}
[Playwright Report](${step_path}/artifacts/playwright-report/index.html) | [Build Log](${step_path}/build-log.txt) | [Logs](${step_path}/artifacts/e2e-test-results/logs/) | [Artifacts](${step_path}/artifacts)"

    curl -sS -X POST -H "Authorization: Bearer ${VAULT_GITHUB_TEST_REPORTER_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/issues/${GIT_PR_NUMBER}/comments" \
        -d "$(jq -n --arg body "$comment" '{body: $body}')" > /dev/null && echo "Posted GitHub comment"
}

# ── Run tests ────────────────────────────────────────────────────────────────

TEST_EXIT_CODE=0

if [[ "$JOB_MODE" == "nightly" ]]; then
    echo "Nightly mode: running selected workspace E2E tests..."
    export E2E_NIGHTLY_MODE="true"

    bash ./run-e2e.sh --workers=4 || TEST_EXIT_CODE=$?
    collect_artifacts
    post_github_comment "Nightly E2E Tests" || echo "WARNING: Failed to post GitHub comment"
    exit $TEST_EXIT_CODE
fi

# ── PR check ─────────────────────────────────────────────────────────────────

PR_CHANGESET=$(git diff --name-only "$RELEASE_BRANCH_NAME")
echo "Changeset: ${PR_CHANGESET}"

CHANGED_WORKSPACES=$(echo "$PR_CHANGESET" | grep '^workspaces/' | cut -d'/' -f2 | sort -u || true)
if [ -z "$CHANGED_WORKSPACES" ]; then
    WORKSPACE_COUNT=0
else
    WORKSPACE_COUNT=$(echo "$CHANGED_WORKSPACES" | wc -l | tr -d ' ')
fi
echo "Changed workspaces: ${CHANGED_WORKSPACES:-none} (count: ${WORKSPACE_COUNT})"

if [ "$WORKSPACE_COUNT" -eq 0 ]; then
    echo "No workspace changes detected. Skipping tests."
    exit 0
elif [ "$WORKSPACE_COUNT" -gt 1 ]; then
    echo "ERROR: Multiple workspaces changed: ${CHANGED_WORKSPACES}"
    exit 1
fi

if [[ ! -f "workspaces/${CHANGED_WORKSPACES}/e2e-tests/package.json" ]]; then
    echo "Workspace '${CHANGED_WORKSPACES}' has no e2e-tests. Skipping."
    exit 0
fi

echo "Running tests for workspace: ${CHANGED_WORKSPACES}"
bash ./run-e2e.sh -w "${CHANGED_WORKSPACES}" || TEST_EXIT_CODE=$?
collect_artifacts
post_github_comment "E2E Tests - \`${CHANGED_WORKSPACES}\`" || echo "WARNING: Failed to post GitHub comment"

exit $TEST_EXIT_CODE
