#!/bin/bash
# E2E step launcher: clone infra-deployments, prepare cluster, run run-e2e.sh.

set -euo pipefail

: "${OVERLAY_E2E_SCRIPT_NAME:=run-e2e.sh}"

OVERLAY_E2E_DIR="components/konflux-operator/ci/openshift-overlay-e2e"
SECRETS_DIR="${KONFLUX_CI_SECRETS_DIR:-/usr/local/konflux-ci-secrets-new/redhat-appstudio-qe}"

export GITHUB_TOKEN
GITHUB_TOKEN="$(cat "${SECRETS_DIR}/github-token")"
GITHUB_USER="${GITHUB_USER:-github-token}"

INFRA_DIR="$(mktemp -d)/infra-deployments"
echo "[INFO] Cloning infra-deployments..."
git clone --origin upstream --branch main \
  "https://${GITHUB_TOKEN}@github.com/redhat-appstudio/infra-deployments.git" "${INFRA_DIR}"
cd "${INFRA_DIR}"

# Merge commits need committer identity; ci_configure_git_credentials runs later (after ci-common.sh).
git config --global user.name "redhat-appstudio-qe-bot"
git config --global user.email redhat-appstudio-qe-bot@redhat.com

if [[ "${REPO_NAME:-}" == "infra-deployments" && -n "${PULL_NUMBER:-}" ]]; then
  echo "[INFO] Fetching infra-deployments PR #${PULL_NUMBER} changes..."
  git fetch upstream "refs/pull/${PULL_NUMBER}/head"
  git merge --no-edit FETCH_HEAD
  echo "[INFO] Merged PR #${PULL_NUMBER} into working tree"
fi

export INFRA_DEPLOYMENTS_ROOT="${INFRA_DIR}"
# shellcheck source=/dev/null
source "${OVERLAY_E2E_DIR}/ci-common.sh"
ci_prepare_cluster_access
ci_configure_git_credentials

echo "[INFO] Running ${OVERLAY_E2E_DIR}/${OVERLAY_E2E_SCRIPT_NAME}"
exec bash "${OVERLAY_E2E_DIR}/${OVERLAY_E2E_SCRIPT_NAME}"
