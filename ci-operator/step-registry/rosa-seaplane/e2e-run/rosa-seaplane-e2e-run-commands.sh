#!/bin/bash
# rosa-seaplane-e2e-run — generic parallel e2e suite runner (ROSAENG-75289).
#
# Knows NOTHING about any particular suite. Flow:
#   1. Clone rosa-seaplane at the provisioned commit (REPO_ROOT: hooks owner).
#   2. Source ${SHARED_DIR}/e2e.env (written by rosa-seaplane-e2e-env) and the
#      optional E2E_SUITE_ENV pass-through, then ci/e2e-hooks/before-suites.sh.
#   3. Check out each suite repo: the job's own source (PR merged into base)
#      for the repo whose CI runs the job, otherwise the pinned commit from
#      e2e.env. Discover suites by folder (ci/e2e/<suite>/run); a suite name
#      defined by two repos fails immediately.
#   4. Validate E2E_SUITES (default: api zoa rosa-cli monitoring); an unknown
#      suite fails before anything starts, listing the available suites.
#   5. Run the selected suites in parallel — each with its own
#      $ARTIFACT_DIR/<suite>, log file, and E2E_SUITE_TIMEOUT — then report
#      PASS/FAIL per suite and source ci/e2e-hooks/after-suites.sh once.

set -euo pipefail

E2E_SUITES="${E2E_SUITES:-api zoa rosa-cli monitoring}"
E2E_SUITE_TIMEOUT="${E2E_SUITE_TIMEOUT:-1h}"

# ---------------------------------------------------------------------------
# 1. rosa-seaplane checkout (platform hooks + suite-repo map).
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
# Capture the path NOW: the trap body expands variables at execution time,
# so a later reassignment of WORK_DIR would leak the original directory.
_E2E_RUN_WORK_DIR="${WORK_DIR}"
trap 'rm -rf "${_E2E_RUN_WORK_DIR}"' EXIT

SOURCE_ENV="${SHARED_DIR}/rosa-seaplane-source.env"
if [[ -r "${SOURCE_ENV}" ]]; then
  # shellcheck source=/dev/null
  source "${SOURCE_ENV}" # sets REPOSITORY_URL and PINNED_SHA
  CLONE_REF="${PINNED_SHA}"
else
  REPOSITORY_URL="https://github.com/openshift-online/rosa-seaplane.git"
  CLONE_REF="${ROSA_REGIONAL_PLATFORM_REF:-main}"
  echo "WARNING: no pinned rosa-seaplane commit — cloning at ref ${CLONE_REF}" >&2
fi

REPO_ROOT="${WORK_DIR}/platform"
git init -q "${REPO_ROOT}"
git -C "${REPO_ROOT}" fetch -q --depth 1 "${REPOSITORY_URL}" "${CLONE_REF}"
git -C "${REPO_ROOT}" checkout -q FETCH_HEAD
export REPO_ROOT
echo "rosa-seaplane (hooks): ${REPOSITORY_URL}@${CLONE_REF}"

# ---------------------------------------------------------------------------
# 2. Environment: e2e.env + E2E_SUITE_ENV + before-suites.sh hook.
# ---------------------------------------------------------------------------
E2E_ENV="${SHARED_DIR}/e2e.env"
if [[ ! -r "${E2E_ENV}" ]]; then
  echo "ERROR: ${E2E_ENV} not found — run the rosa-seaplane-e2e-env step first" >&2
  exit 1
fi
# e2e.env is plain KEY=value: source it with auto-export (set -a) so the
# values reach the suite processes — without it, BASE_URL, RHOBS_API_URL,
# ZOA_*, CLUSTER_PREFIX, OCP_IMAGE and AWS_DEFAULT_REGION would all be
# empty inside ci/e2e/<suite>/run, and dump-env.sh would skip the failure
# dump (it requires CLUSTER_PREFIX in its environment).
set -a
# shellcheck source=/dev/null
source "${E2E_ENV}"
set +a

# Optional pass-through to narrow down inside suites, one KEY=VALUE per line
# (e.g. ROSA_LABEL_FILTER=hyperfleet-sanity). Applied after e2e.env so it wins.
# Comment lines (# ...) and lines that are not KEY=VALUE are skipped so a
# friendly annotation cannot abort the step under set -e.
if [[ -n "${E2E_SUITE_ENV:-}" ]]; then
  while IFS= read -r line; do
    # Require a KEY= assignment on the line: a bare "BASE_URL" would split
    # into k=BASE_URL with an empty v and export BASE_URL= , silently
    # clearing the value loaded from e2e.env. Explicit empty (KEY=) is fine.
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    export "${k}=${v}"
  done <<<"${E2E_SUITE_ENV}"
fi

# shellcheck source=ci/e2e-hooks/before-suites.sh
source "${REPO_ROOT}/ci/e2e-hooks/before-suites.sh"

# ---------------------------------------------------------------------------
# 3. Check out suite repos and discover suites (ci/e2e/<suite>/run).
# ---------------------------------------------------------------------------
API_REPO_URL="https://github.com/openshift-online/rosa-seaplane-api.git"
ZOA_REPO_URL="https://github.com/openshift-online/rosa-seaplane-zoa.git"

# Checks out the PR merged into its base — the same source ci-operator builds
# the images under test from. refs/pull/N/head lives on the upstream repo, so
# fork PRs work too.
checkout_merged_pr() { # <dir> <repo-url>
  local dir="$1" url="$2"
  git init -q "${dir}"
  git -C "${dir}" fetch -q --no-tags "${url}" \
    "refs/heads/${PULL_BASE_REF}" "refs/pull/${PULL_NUMBER}/head"
  git -C "${dir}" checkout -q -b e2e-under-test "${PULL_BASE_SHA}"
  git -C "${dir}" -c user.name=ci -c user.email=ci@openshift.io \
    merge -q --no-ff --no-edit "${PULL_PULL_SHA}"
  echo "Testing ${REPO_NAME} PR #${PULL_NUMBER} (${PULL_PULL_SHA}) merged into ${PULL_BASE_REF} (${PULL_BASE_SHA})"
}

checkout_at() { # <dir> <repo-url> <sha>
  local dir="$1" url="$2" sha="$3"
  git init -q "${dir}"
  git -C "${dir}" fetch -q --depth 1 "${url}" "${sha}"
  git -C "${dir}" checkout -q FETCH_HEAD
  echo "${url}@${sha} -> ${dir}"
}

# The repo whose CI runs the job uses its own source; all others their pins.
if [[ -n "${PULL_NUMBER:-}" && "${REPO_NAME:-}" == "rosa-seaplane-api" ]]; then
  checkout_merged_pr "${WORK_DIR}/rosa-seaplane-api" "${API_REPO_URL}"
elif [[ -n "${E2E_SRC_API:-}" ]]; then
  checkout_at "${WORK_DIR}/rosa-seaplane-api" "${API_REPO_URL}" "${E2E_SRC_API}"
else
  echo "ERROR: no E2E_SRC_API in e2e.env and no rosa-seaplane-api PR context" >&2
  exit 1
fi

if [[ -n "${PULL_NUMBER:-}" && "${REPO_NAME:-}" == "rosa-seaplane-zoa" ]]; then
  checkout_merged_pr "${WORK_DIR}/rosa-seaplane-zoa" "${ZOA_REPO_URL}"
elif [[ -n "${E2E_SRC_ZOA:-}" ]]; then
  checkout_at "${WORK_DIR}/rosa-seaplane-zoa" "${ZOA_REPO_URL}" "${E2E_SRC_ZOA}"
else
  echo "ERROR: no E2E_SRC_ZOA in e2e.env and no rosa-seaplane-zoa PR context" >&2
  exit 1
fi

# The rosa-cli suite (entry point in rosa-seaplane-api) clones the rosa repo
# itself; hand it the pinned ref from e2e.env.
if [[ -n "${E2E_SRC_ROSA_CLI:-}" ]]; then
  export ROSA_REPO_BRANCH="${E2E_SRC_ROSA_CLI}"
fi

# Discovery: every executable ci/e2e/<suite>/run in every suite repo.
declare -A SUITE_REPO
for repo_dir in "${WORK_DIR}/rosa-seaplane-api" "${WORK_DIR}/rosa-seaplane-zoa"; do
  for run in "${repo_dir}"/ci/e2e/*/run; do
    [[ -x "${run}" ]] || continue
    suite="$(basename "$(dirname "${run}")")"
    if [[ -n "${SUITE_REPO[${suite}]:-}" ]]; then
      echo "ERROR: suite '${suite}' is defined by both ${SUITE_REPO[${suite}]} and ${repo_dir}" >&2
      exit 1
    fi
    SUITE_REPO["${suite}"]="${repo_dir}"
  done
done

AVAILABLE="$(printf '%s ' "${!SUITE_REPO[@]}" | xargs)"

# ---------------------------------------------------------------------------
# 4. Validate E2E_SUITES — a typo fails before anything starts.
# ---------------------------------------------------------------------------
SELECTED=()
declare -A SEEN
# Split without glob expansion: a stray *, ? or [] in E2E_SUITES would
# otherwise expand against the working directory before validation.
set -f
read -ra _e2e_suites_words <<<"${E2E_SUITES}"
set +f
for suite in "${_e2e_suites_words[@]}"; do
  if [[ -z "${SUITE_REPO[${suite}]:-}" ]]; then
    echo "ERROR: unknown suite '${suite}' (E2E_SUITES='${E2E_SUITES}')" >&2
    echo "Available suites: ${AVAILABLE:-none}" >&2
    exit 1
  fi
  if [[ -n "${SEEN[${suite}]:-}" ]]; then
    echo "ERROR: duplicate suite '${suite}' in E2E_SUITES — each suite runs once" >&2
    exit 1
  fi
  SEEN["${suite}"]=1
  SELECTED+=("${suite}")
done
if [[ ${#SELECTED[@]} -eq 0 ]]; then
  echo "ERROR: no suites selected (E2E_SUITES='${E2E_SUITES}')" >&2
  echo "Available suites: ${AVAILABLE:-none}" >&2
  exit 1
fi
# A newly added suite is discovered but not part of the documented default;
# surface it so it cannot be silently skipped — job configs opt in by setting
# E2E_SUITES.
for suite in "${!SUITE_REPO[@]}"; do
  if [[ -z "${SEEN[${suite}]:-}" ]]; then
    echo "NOTE: discovered suite '${suite}' is not selected (not in the default "
    echo "      list or E2E_SUITES) — set E2E_SUITES to include it"
  fi
done
echo "Suites (selected): ${SELECTED[*]}"
echo "Suites (available): ${AVAILABLE:-none}"

# A selected suite whose pin is missing must fail loudly: falling back to a
# Makefile default would test an unrelated version (misleading results).
if [[ " ${SELECTED[*]} " == *" rosa-cli "* && -z "${E2E_SRC_ROSA_CLI:-}" ]]; then
  echo "ERROR: suite 'rosa-cli' selected but E2E_SRC_ROSA_CLI is not set — refusing to fall back to an unpinned rosa ref" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Run the selected suites in parallel.
# ---------------------------------------------------------------------------
# Default OUTSIDE WORK_DIR: the EXIT trap deletes WORK_DIR, which would
# lose the artifacts when ARTIFACT_DIR is not set by the caller.
BASE_ARTIFACT_DIR="${ARTIFACT_DIR:-$(mktemp -d)}"
[[ -z "${ARTIFACT_DIR:-}" ]] && echo "ARTIFACT_DIR not set — artifacts defaulting to ${BASE_ARTIFACT_DIR}"
mkdir -p "${BASE_ARTIFACT_DIR}"

declare -A SUITE_PID
for suite in "${SELECTED[@]}"; do
  repo_dir="${SUITE_REPO[${suite}]}"
  suite_artifacts="${BASE_ARTIFACT_DIR}/${suite}"
  mkdir -p "${suite_artifacts}"
  echo "=== suite '${suite}' starting (${repo_dir}, timeout ${E2E_SUITE_TIMEOUT}) ==="
  (
    cd "${repo_dir}"
    export ARTIFACT_DIR="${suite_artifacts}"
    export E2E_SUITE_TIMEOUT
    if timeout --signal=TERM --kill-after=60 "${E2E_SUITE_TIMEOUT}" "./ci/e2e/${suite}/run" \
        > "${suite_artifacts}/suite.log" 2>&1; then
      exit 0
    else
      rc=$?
      if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
        echo "suite '${suite}' timed out after ${E2E_SUITE_TIMEOUT} (TERM ignored, KILLed after 60s grace if rc=137; counted as failure; env dump still runs)" \
          >> "${suite_artifacts}/suite.log"
      fi
      exit "${rc}"
    fi
  ) &
  SUITE_PID["${suite}"]=$!
done

FAILED=0
echo ""
echo "=== E2E Test Summary ==="
for suite in "${SELECTED[@]}"; do
  wait "${SUITE_PID[${suite}]}" && rc=0 || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    printf '  %-20s PASS\n' "${suite}"
  else
    printf '  %-20s FAIL (exit %s, logs: %s)\n' "${suite}" "${rc}" "${BASE_ARTIFACT_DIR}/${suite}/suite.log"
    FAILED=1
  fi
done

# ---------------------------------------------------------------------------
# 6. after-suites.sh once, after all suites finished.
# ---------------------------------------------------------------------------
if [[ "${FAILED}" -eq 0 ]]; then
  export E2E_OVERALL_RESULT=pass
else
  export E2E_OVERALL_RESULT=fail
fi
# shellcheck source=ci/e2e-hooks/after-suites.sh
source "${REPO_ROOT}/ci/e2e-hooks/after-suites.sh"

if [[ "${FAILED}" -ne 0 ]]; then
  echo ""
  echo "Result: FAILED"
  exit 1
fi
echo ""
echo "Result: PASSED"
