#!/usr/bin/env bash

set -euo pipefail

# release-5.0 owns these paths. They contain release-specific Tekton/Konflux
# configuration, downstream packaging, or bundle versions and must not ride
# along with a release-5.1 backport.
readonly PROTECTED_PATHS=(
  .tekton
  .konflux
  Dockerfile.openshift
  Dockerfile.edge.openshift
  openshift
  operator/bundle.Dockerfile.openshift
  operator/bundle
)

readonly REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/openshift-kni/openperouter.git}"
readonly SOURCE_BRANCH="${SOURCE_BRANCH:-release-5.1}"
readonly TARGET_BRANCH="${TARGET_BRANCH:-release-5.0}"
readonly REPORT_DIR="${ARTIFACT_DIR:-${PWD}/artifacts}"
readonly REPORT_FILE="${REPORT_DIR}/openperouter-backport-release-dry-run.txt"

log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "${REPORT_FILE}"
}

is_protected_path() {
  local path="$1"
  local protected
  for protected in "${PROTECTED_PATHS[@]}"; do
    if [[ "${path}" == "${protected}" || "${path}" == "${protected}/"* ]]; then
      return 0
    fi
  done
  return 1
}

cleanup() {
  local status=$?
  if [[ -n "${REPOSITORY_DIR:-}" && -d "${REPOSITORY_DIR}/.git" && -n "${WORKTREE_DIR:-}" && -e "${WORKTREE_DIR}" ]]; then
    git -C "${REPOSITORY_DIR}" worktree remove --force "${WORKTREE_DIR}" || true
  fi
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
  exit "${status}"
}

run_analysis() {
  mkdir -p "${REPORT_DIR}"
  : > "${REPORT_FILE}"

  TEMP_DIR=$(mktemp -d)
  REPOSITORY_DIR="${TEMP_DIR}/openperouter"
  WORKTREE_DIR="${TEMP_DIR}/backport-analysis"
  trap cleanup EXIT

  log "INFO cloning ${REPOSITORY_URL} with full history"
  git clone "${REPOSITORY_URL}" "${REPOSITORY_DIR}"
  git -C "${REPOSITORY_DIR}" fetch --tags origin "${SOURCE_BRANCH}" "${TARGET_BRANCH}"

  # Resolve the refs once so every decision in this run is made against the
  # same immutable source and target commits.
  SOURCE_SHA=$(git -C "${REPOSITORY_DIR}" rev-parse "origin/${SOURCE_BRANCH}^{commit}")
  TARGET_SHA=$(git -C "${REPOSITORY_DIR}" rev-parse "origin/${TARGET_BRANCH}^{commit}")
  log "INFO pinned source ${SOURCE_BRANCH}=${SOURCE_SHA}"
  log "INFO pinned target ${TARGET_BRANCH}=${TARGET_SHA}"

  git -C "${REPOSITORY_DIR}" worktree add --detach "${WORKTREE_DIR}" "${TARGET_SHA}"
  git -C "${WORKTREE_DIR}" switch --create "backport-analysis-${SOURCE_SHA:0:12}" "${TARGET_SHA}"
  log "INFO simulating in temporary worktree ${WORKTREE_DIR}"

  local merge changed_path
  local -a changed_paths
  local eligible_count=0
  local skipped_count=0
  local conflict_count=0
  local applied_count=0
  local total_count=0

  while IFS= read -r merge; do
    [[ -z "${merge}" ]] && continue
    total_count=$((total_count + 1))
    mapfile -t changed_paths < <(git -C "${REPOSITORY_DIR}" diff-tree --no-commit-id --name-only -r "${merge}^1" "${merge}")

    if [[ "${#changed_paths[@]}" -eq 0 ]]; then
      skipped_count=$((skipped_count + 1))
      log "SKIP ${merge} empty first-parent merge"
      continue
    fi

    eligible_count=0
    for changed_path in "${changed_paths[@]}"; do
      if ! is_protected_path "${changed_path}"; then
        eligible_count=$((eligible_count + 1))
      fi
    done
    if [[ "${eligible_count}" -eq 0 ]]; then
      skipped_count=$((skipped_count + 1))
      log "SKIP ${merge} protected-only: ${changed_paths[*]}"
      continue
    fi

    if ! git -C "${WORKTREE_DIR}" cherry-pick -m 1 --no-commit "${merge}"; then
      conflict_count=$((conflict_count + 1))
      log "CONFLICT ${merge}: $(git -C "${WORKTREE_DIR}" diff --name-only --diff-filter=U | tr '\n' ' ')"
      git -C "${WORKTREE_DIR}" reset --hard HEAD
      continue
    fi

    # Restore target-owned/version-bearing paths after every successful pick,
    # before assessing whether the remaining aggregate change is empty.
    git -C "${WORKTREE_DIR}" restore --source="${TARGET_SHA}" --staged --worktree -- "${PROTECTED_PATHS[@]}"
    log "RESTORE ${merge} protected paths from ${TARGET_SHA}"
    if git -C "${WORKTREE_DIR}" diff --cached --quiet && git -C "${WORKTREE_DIR}" diff --quiet; then
      skipped_count=$((skipped_count + 1))
      log "SKIP ${merge} empty after restoring protected paths"
      git -C "${WORKTREE_DIR}" reset --hard HEAD
      continue
    fi

    git -C "${WORKTREE_DIR}" -c user.name='OpenPERouter backport dry-run' -c user.email='noreply@openshift.io' commit --no-verify -C "${merge}"
    applied_count=$((applied_count + 1))
    log "APPLY ${merge} eligible paths=${eligible_count}"
  done < <(git -C "${REPOSITORY_DIR}" rev-list --first-parent --reverse --merges "${TARGET_SHA}..${SOURCE_SHA}")

  log "SUMMARY source=${SOURCE_SHA} target=${TARGET_SHA} total=${total_count} applied=${applied_count} skipped=${skipped_count} conflicts=${conflict_count}"
  log "INFO dry run complete; no push or pull request was created"
}

run_self_test() {
  local fixture
  fixture=$(mktemp -d)
  trap 'rm -rf "${fixture:-}"' EXIT
  local repository="${fixture}/repository"
  local remote="${fixture}/remote.git"

  git init "${repository}"
  git -C "${repository}" config user.name test
  git -C "${repository}" config user.email test@example.invalid
  mkdir -p "${repository}/.tekton" "${repository}/.konflux" "${repository}/openshift" "${repository}/operator/bundle/metadata"
  printf 'base\n' > "${repository}/application"
  printf 'base\n' > "${repository}/conflict-file"
  printf 'target\n' > "${repository}/.tekton/config"
  printf 'target\n' > "${repository}/.konflux/config"
  printf 'target\n' > "${repository}/Dockerfile.openshift"
  printf 'target\n' > "${repository}/Dockerfile.edge.openshift"
  printf 'target\n' > "${repository}/openshift/package"
  printf 'target\n' > "${repository}/operator/bundle.Dockerfile.openshift"
  printf 'target\n' > "${repository}/operator/bundle/metadata/annotations.yaml"
  git -C "${repository}" add .
  git -C "${repository}" commit -m base
  git -C "${repository}" branch release-5.0
  git -C "${repository}" switch -c release-5.1

  git -C "${repository}" switch -c eligible
  printf 'eligible\n' >> "${repository}/application"
  printf 'source\n' > "${repository}/.tekton/config"
  git -C "${repository}" add application .tekton/config
  git -C "${repository}" commit -m eligible
  git -C "${repository}" switch release-5.1
  git -C "${repository}" merge --no-ff eligible -m 'Merge eligible'

  git -C "${repository}" switch -c protected-only
  printf 'protected-only\n' > "${repository}/.tekton/config"
  git -C "${repository}" add .tekton/config
  git -C "${repository}" commit -m protected-only
  git -C "${repository}" switch release-5.1
  git -C "${repository}" merge --no-ff protected-only -m 'Merge protected-only'

  git -C "${repository}" switch release-5.0
  printf 'target conflict\n' > "${repository}/conflict-file"
  git -C "${repository}" add conflict-file
  git -C "${repository}" commit -m target-conflict
  git -C "${repository}" switch release-5.1
  git -C "${repository}" switch -c conflicting
  printf 'source conflict\n' > "${repository}/conflict-file"
  git -C "${repository}" add conflict-file
  git -C "${repository}" commit -m conflicting
  git -C "${repository}" switch release-5.1
  git -C "${repository}" merge --no-ff conflicting -m 'Merge conflicting'
  git clone --bare "${repository}" "${remote}"

  env BACKPORT_ANALYSIS_TEST_MODE=false REPOSITORY_URL="${remote}" SOURCE_BRANCH=release-5.1 TARGET_BRANCH=release-5.0 ARTIFACT_DIR="${fixture}/artifacts" "$0"
  grep -q 'APPLY ' "${fixture}/artifacts/openperouter-backport-release-dry-run.txt"
  grep -q 'RESTORE ' "${fixture}/artifacts/openperouter-backport-release-dry-run.txt"
  grep -q 'protected-only' "${fixture}/artifacts/openperouter-backport-release-dry-run.txt"
  grep -q 'CONFLICT ' "${fixture}/artifacts/openperouter-backport-release-dry-run.txt"
  printf 'self-test passed\n'
}

if [[ "${BACKPORT_ANALYSIS_TEST_MODE:-false}" == "true" ]]; then
  run_self_test
else
  run_analysis
fi
