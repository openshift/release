#!/bin/bash

# Regression tests for the ROSA upgrade target/channel auto-derivation.
#
# The upgrade steps must pick the next Y-stream from the version-sorted list of
# available Y-streams, mirroring how VERSION_OFFSET_FROM_LATEST resolves the install
# version in rosa/cluster/provision and rosa/sts/account-roles/create. Deriving the
# target by incrementing the minor number breaks at a major boundary (4.22 -> 5.0),
# producing a channel that OCM rejects.
#
# These tests exercise the real helper functions AND the real selection blocks lifted
# out of the step scripts, with the `rosa` CLI replaced by a shell-function stub. No
# test contacts OCM, AWS, or any cluster.
#
# Run with: make test-rosa-upgrade-target-selection

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${REPO_ROOT}/ci-operator/step-registry/rosa"
CLASSIC_SCRIPT="${REGISTRY}/cluster/upgrade/cluster/rosa-cluster-upgrade-cluster-commands.sh"
HCP_SCRIPT="${REGISTRY}/cluster/upgrade/hcp/rosa-cluster-upgrade-hcp-commands.sh"
PROVISION_SCRIPT="${REGISTRY}/cluster/provision/rosa-cluster-provision-commands.sh"
ACCOUNT_ROLES_SCRIPT="${REGISTRY}/sts/account-roles/create/rosa-sts-account-roles-create-commands.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

pass() {
  echo "PASS: $*"
}

extract_function() {
  sed -n "/^$2()/,/^}/p" "$1"
}

# The selection block runs at top level in each step script, between the first
# current_y_stream assignment and the final diagnostics call.
extract_selection_block() {
  sed -n '/^current_y_stream=/,/^write_target_selection_diagnostics /p' "$1"
}

for script in "${CLASSIC_SCRIPT}" "${HCP_SCRIPT}" "${PROVISION_SCRIPT}" "${ACCOUNT_ROLES_SCRIPT}"; do
  [[ -f "${script}" ]] || { echo "FAIL: missing script ${script}"; exit 1; }
done

###############################################################################
# 1. The shared helper must not drift between the two upgrade steps.
###############################################################################

for fn in next_y_stream_after list_available_y_streams write_target_selection_diagnostics; do
  if [[ -z "$(extract_function "${CLASSIC_SCRIPT}" "${fn}")" ]]; then
    fail "could not extract ${fn} from the classic upgrade step"
    continue
  fi
  if [[ -z "$(extract_function "${HCP_SCRIPT}" "${fn}")" ]]; then
    fail "could not extract ${fn} from the HCP upgrade step"
    continue
  fi
done

# list_available_y_streams intentionally differs (the HCP step always passes
# --hosted-cp), but these two must stay in lockstep across both steps.
for fn in next_y_stream_after write_target_selection_diagnostics; do
  if diff -u <(extract_function "${CLASSIC_SCRIPT}" "${fn}") \
             <(extract_function "${HCP_SCRIPT}" "${fn}") > "${WORKDIR}/drift-${fn}.diff"; then
    pass "${fn} is identical in the classic and HCP upgrade steps"
  else
    cat "${WORKDIR}/drift-${fn}.diff"
    fail "${fn} differs between the classic and HCP upgrade steps"
  fi
done

###############################################################################
# 2. The discovery query must keep the same shape as the install side, which is
#    what defines the VERSION_OFFSET_FROM_LATEST ordering the target depends on.
###############################################################################

# Normalise whitespace and quoting so cosmetic differences (cut -d'.' vs cut -d '.')
# do not fail; only the actual query shape and data schema are compared.
squash() { tr -s ' ' ' ' < "$1" | tr -d "'\"" | sed 's/-d \./-d./g'; }

assert_contains() {
  local name="$1" file="$2" needle="$3"
  if squash "${file}" | grep -qF -- "${needle}"; then
    pass "${name}: contains '${needle}'"
  else
    fail "${name}: expected to contain '${needle}'"
  fi
}

for probe in "rosa list versions --channel-group" "--hosted-cp" ".[].raw_id" "cut -d. -f1,2" "sort -Vu"; do
  assert_contains "install source (provision)" "${PROVISION_SCRIPT}" "${probe}"
done
for probe in "rosa list versions --channel-group" ".[].raw_id" "cut -d. -f1,2" "sort -Vu"; do
  assert_contains "install source (account-roles)" "${ACCOUNT_ROLES_SCRIPT}" "${probe}"
  assert_contains "upgrade step (classic)" "${CLASSIC_SCRIPT}" "${probe}"
  assert_contains "upgrade step (HCP)" "${HCP_SCRIPT}" "${probe}"
done
assert_contains "upgrade step (classic)" "${CLASSIC_SCRIPT}" "--hosted-cp"
assert_contains "upgrade step (HCP)" "${HCP_SCRIPT}" "--hosted-cp"

###############################################################################
# 3. Pure-function tests for next_y_stream_after.
###############################################################################

# shellcheck disable=SC1090,SC1091
source /dev/stdin <<< "$(extract_function "${CLASSIC_SCRIPT}" next_y_stream_after)"

expect_target() {
  local name="$1" current="$2" list="$3" want="$4"
  local got status=0
  got=$(next_y_stream_after "${current}" "${list}") || status=$?
  if [[ ${status} -ne 0 ]]; then
    fail "${name}: expected ${want}, but the helper returned status ${status}"
  elif [[ "${got}" != "${want}" ]]; then
    fail "${name}: expected ${want}, got ${got}"
  else
    pass "${name}: ${current} -> ${got}"
  fi
}

expect_failure() {
  local name="$1" current="$2" list="$3"
  local got status=0
  got=$(next_y_stream_after "${current}" "${list}") || status=$?
  if [[ ${status} -eq 0 ]]; then
    fail "${name}: expected a non-zero status, but got target '${got}'"
  elif [[ -n "${got}" ]]; then
    fail "${name}: expected no output on failure, got '${got}'"
  else
    pass "${name}: ${current} correctly refused (status ${status})"
  fi
}

expect_target "ordinary minor" "4.20.3" "$(printf '4.19\n4.20\n4.21\n4.22\n')" "4.21"
expect_target "major boundary" "4.22.1" "$(printf '4.20\n4.21\n4.22\n5.0\n')" "5.0"
expect_target "gap in minors" "4.20.0" "$(printf '4.20\n4.22\n')" "4.22"
expect_target "version order not lexical" "4.9.1" "$(printf '4.9\n4.10\n')" "4.10"
expect_target "blank entries ignored" "4.21.0" "$(printf '4.21\n\n4.22\n')" "4.22"
expect_target "malformed entries ignored" "4.21.0" "$(printf 'null\n4.21\nnightly\n4.22\n')" "4.22"

expect_failure "already newest" "5.0.0" "$(printf '4.22\n5.0\n')"
expect_failure "no newer stream" "4.22.1" "$(printf '4.20\n4.21\n4.22\n')"
expect_failure "empty list" "4.22.1" ""
# sort -V ranks "null" after numeric streams, so without the X.Y guard this returned
# "null" and the caller built the bogus channel "candidate-null".
expect_failure "null is never selected" "4.22.1" "$(printf '4.22\nnull\n')"
expect_failure "all entries malformed" "4.22.1" "$(printf 'null\nnightly\n')"
expect_failure "malformed current version" "not-a-version" "$(printf '4.22\n5.0\n')"

###############################################################################
# 4. Mocked end-to-end tests of the real selection blocks.
###############################################################################

# Builds a runnable harness: the three real helpers plus the real selection block,
# with `rosa` replaced by a stub that records its arguments.
# The single-quoted echo lines below are emitted verbatim into the harness script and
# must NOT expand here, so SC2016 is expected throughout this function.
# shellcheck disable=SC2016
build_harness() {
  local src="$1" out="$2"
  {
    echo '#!/bin/bash'
    echo 'set -o nounset'
    echo 'set -o errexit'
    echo 'set -o pipefail'
    echo 'log() { echo "LOG: $*" >&2; }'
    echo 'rosa() {'
    echo '  echo "$*" >> "${ROSA_CALL_LOG}"'
    echo '  if [[ -n "${ROSA_FAIL:-}" ]]; then return 1; fi'
    echo '  printf "%s" "${ROSA_JSON:-[]}"'
    echo '}'
    extract_function "${src}" list_available_y_streams
    extract_function "${src}" next_y_stream_after
    extract_function "${src}" write_target_selection_diagnostics
    extract_selection_block "${src}"
    echo 'echo "RESULT_TARGET=${UPGRADED_TO_VERSION:-}"'
    echo 'echo "RESULT_CHANNEL=${UPGRADE_CHANNEL:-}"'
  } > "${out}"
}

CLASSIC_HARNESS="${WORKDIR}/classic-harness.sh"
HCP_HARNESS="${WORKDIR}/hcp-harness.sh"
build_harness "${CLASSIC_SCRIPT}" "${CLASSIC_HARNESS}"
build_harness "${HCP_SCRIPT}" "${HCP_HARNESS}"

for h in "${CLASSIC_HARNESS}" "${HCP_HARNESS}"; do
  if bash -n "${h}"; then
    pass "harness built from $(basename "${h%%-harness.sh}") parses"
  else
    fail "harness from ${h} does not parse"
  fi
done

# run_case <name> <harness> <expected-exit> <env assignments...>
# Exports ROSA_CALL_LOG/ARTIFACT_DIR per case and captures stdout/stderr.
CASE_N=0
run_case() {
  local name="$1" harness="$2" want_exit="$3"; shift 3
  CASE_N=$((CASE_N + 1))
  local dir="${WORKDIR}/case${CASE_N}"
  mkdir -p "${dir}/artifacts"
  CASE_DIR="${dir}"
  CASE_LOG="${dir}/rosa-calls.txt"
  CASE_ART="${dir}/artifacts"
  : > "${CASE_LOG}"
  local status=0
  ( env "$@" \
        ROSA_CALL_LOG="${CASE_LOG}" \
        ARTIFACT_DIR="${CASE_ART}" \
        bash "${harness}" ) > "${dir}/stdout" 2> "${dir}/stderr" || status=$?
  if [[ "${status}" -ne "${want_exit}" ]]; then
    fail "${name}: expected exit ${want_exit}, got ${status}"
    sed 's/^/    /' "${dir}/stderr" | tail -3
    return 1
  fi
  return 0
}

result_of() { grep "^$1=" "${CASE_DIR}/stdout" | cut -d= -f2- || true; }

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then
    pass "${name} (= '${want}')"
  else
    fail "${name}: expected '${want}', got '${got}'"
  fi
}

assert_no_rosa_call() {
  local name="$1"
  if [[ -s "${CASE_LOG}" ]]; then
    fail "${name}: expected no rosa query, but got: $(tr '\n' ';' < "${CASE_LOG}")"
  else
    pass "${name}: no rosa query issued"
  fi
}

VERSIONS_BOUNDARY='[{"raw_id":"4.21.9"},{"raw_id":"4.22.3"},{"raw_id":"5.0.1"}]'
VERSIONS_NULL='[{"raw_id":"4.22.3"},{"raw_id":null},{"id":"no-raw-id"}]'
VERSIONS_EMPTY='[]'

## --- Classic ---------------------------------------------------------------

if run_case "classic/auto major boundary" "${CLASSIC_HARNESS}" 0 \
    current_version=4.22.3 UPGRADED_TO_VERSION= UPGRADE_CHANNEL= \
    UPGRADE_CHANNEL_PREFIX=candidate CHANNEL_GROUP=stable HOSTED_CP=false \
    ROSA_JSON="${VERSIONS_BOUNDARY}"; then
  assert_eq "classic/auto major boundary: target" "$(result_of RESULT_TARGET)" "5.0"
  assert_eq "classic/auto major boundary: channel" "$(result_of RESULT_CHANNEL)" "candidate-5.0"
  assert_eq "classic/auto major boundary: query" "$(cat "${CASE_LOG}")" \
    "list versions --channel-group stable -o json"
  if grep -q "selected_target: 5.0" "${CASE_ART}/upgrade-target-selection.txt"; then
    pass "classic/auto major boundary: diagnostics record the selection"
  else
    fail "classic/auto major boundary: diagnostics missing selected_target"
  fi
fi

if run_case "classic/hosted-cp flag" "${CLASSIC_HARNESS}" 0 \
    current_version=4.22.3 UPGRADED_TO_VERSION= UPGRADE_CHANNEL= \
    UPGRADE_CHANNEL_PREFIX=candidate CHANNEL_GROUP=candidate HOSTED_CP=true \
    ROSA_JSON="${VERSIONS_BOUNDARY}"; then
  assert_eq "classic/hosted-cp flag: query" "$(cat "${CASE_LOG}")" \
    "list versions --channel-group candidate -o json --hosted-cp"
fi

if run_case "classic/explicit override" "${CLASSIC_HARNESS}" 0 \
    current_version=4.22.3 UPGRADED_TO_VERSION=4.25 UPGRADE_CHANNEL=fast-4.25 \
    UPGRADE_CHANNEL_PREFIX=candidate CHANNEL_GROUP=stable HOSTED_CP=false \
    ROSA_JSON="${VERSIONS_BOUNDARY}"; then
  assert_eq "classic/explicit override: target preserved" "$(result_of RESULT_TARGET)" "4.25"
  assert_eq "classic/explicit override: channel preserved" "$(result_of RESULT_CHANNEL)" "fast-4.25"
  assert_no_rosa_call "classic/explicit override"
fi

if run_case "classic/explicit target only" "${CLASSIC_HARNESS}" 0 \
    current_version=4.22.3 UPGRADED_TO_VERSION=5.0 UPGRADE_CHANNEL= \
    UPGRADE_CHANNEL_PREFIX=candidate CHANNEL_GROUP=stable HOSTED_CP=false \
    ROSA_JSON="${VERSIONS_BOUNDARY}"; then
  assert_eq "classic/explicit target only: channel derived" "$(result_of RESULT_CHANNEL)" "candidate-5.0"
  assert_no_rosa_call "classic/explicit target only"
fi

if run_case "classic/query failure" "${CLASSIC_HARNESS}" 1 \
    current_version=4.22.3 UPGRADED_TO_VERSION= UPGRADE_CHANNEL= \
    UPGRADE_CHANNEL_PREFIX=candidate CHANNEL_GROUP=stable HOSTED_CP=false \
    ROSA_FAIL=1 ROSA_JSON="${VERSIONS_BOUNDARY}"; then
  pass "classic/query failure: step exits non-zero"
  if [[ -f "${CASE_ART}/upgrade-target-selection.txt" ]]; then
    pass "classic/query failure: early diagnostics artifact written"
  else
    fail "classic/query failure: no diagnostics artifact"
  fi
fi

if run_case "classic/invalid json" "${CLASSIC_HARNESS}" 1 \
    current_version=4.22.3 UPGRADED_TO_VERSION= UPGRADE_CHANNEL= \
    UPGRADE_CHANNEL_PREFIX=candidate CHANNEL_GROUP=stable HOSTED_CP=false \
    ROSA_JSON='not json at all'; then
  pass "classic/invalid json: step exits non-zero"
fi

if run_case "classic/null raw_id" "${CLASSIC_HARNESS}" 1 \
    current_version=4.22.3 UPGRADED_TO_VERSION= UPGRADE_CHANNEL= \
    UPGRADE_CHANNEL_PREFIX=candidate CHANNEL_GROUP=stable HOSTED_CP=false \
    ROSA_JSON="${VERSIONS_NULL}"; then
  pass "classic/null raw_id: step exits non-zero instead of selecting null"
  if grep -q 'null' "${CASE_ART}/upgrade-target-selection.txt" 2>/dev/null; then
    fail "classic/null raw_id: 'null' leaked into the diagnostics artifact"
  else
    pass "classic/null raw_id: no 'null' in diagnostics artifact"
  fi
fi

if run_case "classic/empty version list" "${CLASSIC_HARNESS}" 1 \
    current_version=4.22.3 UPGRADED_TO_VERSION= UPGRADE_CHANNEL= \
    UPGRADE_CHANNEL_PREFIX=candidate CHANNEL_GROUP=stable HOSTED_CP=false \
    ROSA_JSON="${VERSIONS_EMPTY}"; then
  pass "classic/empty version list: step exits non-zero"
fi

## --- HCP -------------------------------------------------------------------

if run_case "hcp/auto major boundary" "${HCP_HARNESS}" 0 \
    init_version=4.22.3 UPGRADE_CHANNEL= UPGRADE_CHANNEL_PREFIX=candidate \
    CHANNEL_GROUP=stable Z_STREAM_UPGRADE=false \
    ROSA_JSON="${VERSIONS_BOUNDARY}"; then
  assert_eq "hcp/auto major boundary: channel" "$(result_of RESULT_CHANNEL)" "candidate-5.0"
  assert_eq "hcp/auto major boundary: query" "$(cat "${CASE_LOG}")" \
    "list versions --channel-group stable --hosted-cp -o json"
fi

if run_case "hcp/z-stream bypass" "${HCP_HARNESS}" 0 \
    init_version=4.22.3 UPGRADE_CHANNEL= UPGRADE_CHANNEL_PREFIX=candidate \
    CHANNEL_GROUP=stable Z_STREAM_UPGRADE=true \
    ROSA_JSON="${VERSIONS_BOUNDARY}"; then
  assert_eq "hcp/z-stream bypass: channel stays empty" "$(result_of RESULT_CHANNEL)" ""
  assert_no_rosa_call "hcp/z-stream bypass"
fi

if run_case "hcp/explicit channel" "${HCP_HARNESS}" 0 \
    init_version=4.22.3 UPGRADE_CHANNEL=candidate-5.0 UPGRADE_CHANNEL_PREFIX=candidate \
    CHANNEL_GROUP=stable Z_STREAM_UPGRADE=false \
    ROSA_JSON="${VERSIONS_BOUNDARY}"; then
  assert_eq "hcp/explicit channel: preserved" "$(result_of RESULT_CHANNEL)" "candidate-5.0"
  assert_no_rosa_call "hcp/explicit channel"
fi

if run_case "hcp/null raw_id" "${HCP_HARNESS}" 1 \
    init_version=4.22.3 UPGRADE_CHANNEL= UPGRADE_CHANNEL_PREFIX=candidate \
    CHANNEL_GROUP=stable Z_STREAM_UPGRADE=false \
    ROSA_JSON="${VERSIONS_NULL}"; then
  pass "hcp/null raw_id: step exits non-zero instead of building candidate-null"
fi

if run_case "hcp/query failure" "${HCP_HARNESS}" 1 \
    init_version=4.22.3 UPGRADE_CHANNEL= UPGRADE_CHANNEL_PREFIX=candidate \
    CHANNEL_GROUP=stable Z_STREAM_UPGRADE=false \
    ROSA_FAIL=1; then
  pass "hcp/query failure: step exits non-zero"
fi

###############################################################################

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "All ROSA upgrade target selection tests passed"
