#!/bin/bash

# Regression tests for the ROSA upgrade target/channel auto-derivation.
#
# The upgrade steps must pick the next Y-stream from the version-sorted list of
# available Y-streams, mirroring how VERSION_OFFSET_FROM_LATEST resolves the install
# version in rosa/cluster/provision and rosa/sts/account-roles/create. Deriving the
# target by incrementing the minor number breaks at a major boundary (4.22 -> 5.0),
# producing a channel that OCM rejects.
#
# Run with: make test-rosa-upgrade-target-selection

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIC_SCRIPT="${REPO_ROOT}/ci-operator/step-registry/rosa/cluster/upgrade/cluster/rosa-cluster-upgrade-cluster-commands.sh"
HCP_SCRIPT="${REPO_ROOT}/ci-operator/step-registry/rosa/cluster/upgrade/hcp/rosa-cluster-upgrade-hcp-commands.sh"

extract_function() {
  sed -n '/^next_y_stream_after()/,/^}/p' "$1"
}

for script in "${CLASSIC_SCRIPT}" "${HCP_SCRIPT}"; do
  if [[ ! -f "${script}" ]]; then
    echo "FAIL: missing script ${script}"
    exit 1
  fi
  if [[ -z "$(extract_function "${script}")" ]]; then
    echo "FAIL: could not extract next_y_stream_after from ${script}"
    exit 1
  fi
done

# The two steps carry independent copies of the helper; keep them from drifting apart.
if ! diff -u <(extract_function "${CLASSIC_SCRIPT}") <(extract_function "${HCP_SCRIPT}"); then
  echo "FAIL: next_y_stream_after differs between the classic and HCP upgrade steps"
  exit 1
fi
echo "PASS: next_y_stream_after is identical in the classic and HCP upgrade steps"

# shellcheck disable=SC1090,SC1091
source /dev/stdin <<< "$(extract_function "${CLASSIC_SCRIPT}")"

failures=0

expect_target() {
  local name="$1" current="$2" list="$3" want="$4"
  local got status=0
  got=$(next_y_stream_after "${current}" "${list}") || status=$?
  if [[ ${status} -ne 0 ]]; then
    echo "FAIL: ${name}: expected ${want}, but the helper returned status ${status}"
    failures=$((failures + 1))
    return
  fi
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: ${name}: expected ${want}, got ${got}"
    failures=$((failures + 1))
    return
  fi
  echo "PASS: ${name}: ${current} -> ${got}"
}

expect_failure() {
  local name="$1" current="$2" list="$3"
  local got status=0
  got=$(next_y_stream_after "${current}" "${list}") || status=$?
  if [[ ${status} -eq 0 ]]; then
    echo "FAIL: ${name}: expected a non-zero status, but got target '${got}'"
    failures=$((failures + 1))
    return
  fi
  if [[ -n "${got}" ]]; then
    echo "FAIL: ${name}: expected no output on failure, got '${got}'"
    failures=$((failures + 1))
    return
  fi
  echo "PASS: ${name}: ${current} correctly refused (status ${status})"
}

# An ordinary Y-stream upgrade inside one major.
expect_target "ordinary minor" "4.20.3" "$(printf '4.19\n4.20\n4.21\n4.22\n')" "4.21"

# The reported incident: the next stream opens a new major, so minor+1 (4.23) is wrong.
expect_target "major boundary" "4.22.1" "$(printf '4.20\n4.21\n4.22\n5.0\n')" "5.0"

# A missing intermediate stream must not produce a non-existent target.
expect_target "gap in minors" "4.20.0" "$(printf '4.20\n4.22\n')" "4.22"

# Version ordering, not lexical ordering: 4.10 is newer than 4.9.
expect_target "version order not lexical" "4.9.1" "$(printf '4.9\n4.10\n')" "4.10"

# Blank entries in the discovered list must be ignored rather than selected.
expect_target "blank entries ignored" "4.21.0" "$(printf '4.21\n\n4.22\n')" "4.22"

# Fail closed: already on the newest stream. No same-stream or downgrade fallback.
expect_failure "already newest" "5.0.0" "$(printf '4.22\n5.0\n')"

# Fail closed: nothing newer than the current stream is available.
expect_failure "no newer stream" "4.22.1" "$(printf '4.20\n4.21\n4.22\n')"

# Fail closed: discovery returned nothing.
expect_failure "empty list" "4.22.1" ""

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "All ROSA upgrade target selection tests passed"
