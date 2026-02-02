#!/bin/bash
set -euo pipefail

# =============================================================================
# RHDH Plugin Export Overlays - E2E Test Runner
# Runs e2e tests for a single workspace changed in a PR.
# =============================================================================

# Configuration
GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh-plugin-export-overlays"
REHEARSE_PR_NUMBER=""  # for rehearse testing give overlay repo PR number.

# Environment setup
export HOME=/tmp
export CI=true
cd /tmp

# Export VAULT_ secrets
for file in /tmp/secrets/*; do
    [[ -f "$file" ]] || continue
    filename=$(basename "$file")
    [[ "$filename" == *"secretsync-vault-source-path"* ]] && continue
    [[ "$filename" == VAULT_* ]] || continue
    export "$filename"="$(cat "$file")"
done

# Parse job spec
RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "Repository: ${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}"
echo "Branch: ${RELEASE_BRANCH_NAME}, PR: ${GIT_PR_NUMBER}"

# Cluster authentication
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

# Service account setup
export K8S_CLUSTER_URL K8S_CLUSTER_TOKEN
K8S_CLUSTER_URL=$(oc whoami --show-server)
oc create serviceaccount tester-sa-2 -n default
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2
K8S_CLUSTER_TOKEN=$(oc create token tester-sa-2 -n default --duration=4h)

# Platform environment
export IS_OPENSHIFT="true"
export CI="true"
export CONTAINER_PLATFORM="ocp"
export CONTAINER_PLATFORM_VERSION
CONTAINER_PLATFORM_VERSION=$(oc version --output json 2>/dev/null | jq -r '.openshiftVersion' | cut -d'.' -f1,2 || echo "unknown")
echo "Platform: ${CONTAINER_PLATFORM} ${CONTAINER_PLATFORM_VERSION}"

# Clone repository
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}"
git checkout "$RELEASE_BRANCH_NAME"
git config --global user.name "rhdh-qe"
git config --global user.email "rhdh-qe@redhat.com"

# PR checkout
if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    git fetch origin "pull/${GIT_PR_NUMBER}/head:PR${GIT_PR_NUMBER}"
    git checkout "PR${GIT_PR_NUMBER}"
    git merge "origin/${RELEASE_BRANCH_NAME}" --no-edit
elif [[ "$JOB_NAME" == rehearse-* ]] && [ -n "$REHEARSE_PR_NUMBER" ]; then
    echo "Rehearsal mode: testing against PR #${REHEARSE_PR_NUMBER}"
    GIT_PR_NUMBER="$REHEARSE_PR_NUMBER"
    git fetch origin "pull/${GIT_PR_NUMBER}/head:PR${GIT_PR_NUMBER}"
    git checkout "PR${GIT_PR_NUMBER}"
    git merge "origin/${RELEASE_BRANCH_NAME}" --no-edit
fi

# RHDH environment
export RHDH_VERSION INSTALLATION_METHOD
if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
    RHDH_VERSION="$(echo "$RELEASE_BRANCH_NAME" | cut -d'-' -f2)"
else
    RHDH_VERSION="next"
fi
INSTALLATION_METHOD="helm"
echo "RHDH_VERSION: ${RHDH_VERSION}, INSTALLATION_METHOD: ${INSTALLATION_METHOD}"

# Workspace detection
PR_CHANGESET=$(git diff --name-only "$RELEASE_BRANCH_NAME")
echo "Changeset: ${PR_CHANGESET}"

CHANGED_WORKSPACES=$(echo "$PR_CHANGESET" | grep '^workspaces/' | cut -d'/' -f2 | sort -u || true)
if [ -z "$CHANGED_WORKSPACES" ]; then
    WORKSPACE_COUNT=0
else
    WORKSPACE_COUNT=$(echo "$CHANGED_WORKSPACES" | wc -l | tr -d ' ')
fi
echo "Changed workspaces: ${CHANGED_WORKSPACES:-none} (count: ${WORKSPACE_COUNT})"

# Test execution
if [ "$WORKSPACE_COUNT" -eq 0 ]; then
    echo "No workspace changes detected. Skipping tests."
    exit 0
elif [ "$WORKSPACE_COUNT" -gt 1 ]; then
    echo "ERROR: Multiple workspaces changed: ${CHANGED_WORKSPACES}"
    exit 1
fi

echo "Running tests for workspace: ${CHANGED_WORKSPACES}"
cd "workspaces/${CHANGED_WORKSPACES}/e2e-tests"
yarn install

TEST_EXIT_CODE=0
yarn test || TEST_EXIT_CODE=$?

# Copy test artifacts regardless of test result
echo "Copying test artifacts to ${ARTIFACT_DIR}"
cp -a playwright-report "${ARTIFACT_DIR}/" 2>/dev/null || true
cp -a node_modules/.cache/e2e-test-results "${ARTIFACT_DIR}/" 2>/dev/null || true

# Post GitHub comment with test results
post_github_comment() {
    set +ex  # Disable exit-on-error and tracing for token handling
    [[ "$JOB_TYPE" != "presubmit" ]] && [[ -z "${REHEARSE_PR_NUMBER:-}" ]] && return 0
    [[ -z "${VAULT_GITHUB_TEST_REPORTER_TOKEN:-}" ]] && { echo "WARNING: VAULT_GITHUB_TEST_REPORTER_TOKEN not set"; return 1; }

    local gcs_base="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull"
    local step_path="${gcs_base}/${GITHUB_ORG_NAME}_${GITHUB_REPOSITORY_NAME}/${GIT_PR_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/e2e-ocp-helm/redhat-developer-rhdh-plugin-export-overlays-ocp-helm"
    local stats status comment

    stats=$(jq -r '(.stats.duration // 0) / 1000 | floor | "\(. / 60 | floor)m \(. % 60)s"' playwright-report/results.json 2>/dev/null || echo "N/A")
    counts=$(jq -r '"Passed: \(.stats.expected // 0) | Failed: \(.stats.unexpected // 0) | Flaky: \(.stats.flaky // 0) | Skipped: \(.stats.skipped // 0)"' playwright-report/results.json 2>/dev/null || echo "N/A")
    [[ "$TEST_EXIT_CODE" -eq 0 ]] && status="✅ Passed" || status="❌ Failed"

    comment="### ${status} E2E Tests - \`${CHANGED_WORKSPACES}\`
**Platform:** ${CONTAINER_PLATFORM} ${CONTAINER_PLATFORM_VERSION} | **RHDH Version:** ${RHDH_VERSION} | **Duration:** ${stats}
${counts}
[Playwright Report](${step_path}/artifacts/playwright-report/index.html) | [Build Log](${step_path}/build-log.txt) | [Artifacts](${step_path}/artifacts)"

    curl -sS -X POST -H "Authorization: Bearer ${VAULT_GITHUB_TEST_REPORTER_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/issues/${GIT_PR_NUMBER}/comments" \
        -d "$(jq -n --arg body "$comment" '{body: $body}')" > /dev/null && echo "Posted GitHub comment"
}
post_github_comment || echo "WARNING: Failed to post GitHub comment"

exit $TEST_EXIT_CODE
