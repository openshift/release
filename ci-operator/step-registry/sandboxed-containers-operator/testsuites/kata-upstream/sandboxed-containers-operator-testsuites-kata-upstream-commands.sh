#!/bin/bash

set -euo pipefail
# No -x: this step only echoes non-sensitive values. It does not print the
# kubeconfig or any credentials. Exit code mirrors the upstream runner.

# Enable-gate: skip-by-default so the suite stays non-blocking in the post chain.
ENABLE="${TESTS_KATA_UPSTREAM_ENABLE:-false}"

echo "=========================================="
echo "OSC testsuites :: kata-upstream"
echo "TESTS_KATA_UPSTREAM_ENABLE=${ENABLE}"
echo "=========================================="

if [[ "${ENABLE}" != "true" ]]; then
    echo "kata-upstream suite disabled (TESTS_KATA_UPSTREAM_ENABLE=${ENABLE}); exiting 0."
    cat > "${ARTIFACT_DIR}/junit_kata_upstream_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="kata-upstream" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="kata-upstream" classname="osc.testsuites.kata-upstream" time="0">
    <skipped message="TESTS_KATA_UPSTREAM_ENABLE=${ENABLE}"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Configuration -----------------------------------------------------------
# The upstream test runner lives in the operator repo. We always run the
# runner from the development branch.
OPERATOR_REPO="https://github.com/openshift/sandboxed-containers-operator"
OPERATOR_REF="devel"

# User-facing parameters (see the ref for defaults/documentation). They follow
# the TESTS_<SUITE_NAME>_<PARAMETER> convention shared by all OSC test suites:
#   TESTS_KATA_UPSTREAM_PROFILE   -> runner -t/--test
#   TESTS_KATA_UPSTREAM_REPO      -> runner --tests-repo
#   TESTS_KATA_UPSTREAM_REPO_REF  -> runner --tests-repo-ref
# Empty values are omitted so the runner falls back to its own defaults.
TEST_PROFILE="${TESTS_KATA_UPSTREAM_PROFILE:-full}"
TESTS_REPO="${TESTS_KATA_UPSTREAM_REPO:-}"
TESTS_REPO_REF="${TESTS_KATA_UPSTREAM_REPO_REF:-}"

# --- Provide the tools the runner needs ---------------------------------------
# The runner requires: bats yq jq kubectl envsubst oc git. git comes from the
# src image, oc is injected via the ref's `cli` field; anything still missing is
# installed on-demand into a writable dir. Every downloaded artifact is pinned
# to a version and verified against a recorded SHA-256 to guard against
# tampering. (Long term these tools should ship in a pre-built image.)
BINDIR="/tmp/bin"
mkdir -p "${BINDIR}"
export PATH="${BINDIR}:${PATH}"

# oc is kubectl-compatible; expose it as kubectl since only oc is injected.
command -v kubectl >/dev/null 2>&1 || ln -sf "$(command -v oc)" "${BINDIR}/kubectl"

# install_verified URL DEST SHA256
install_verified() {
    local url="$1" dest="$2" sha="$3"
    echo "Installing $(basename "${dest}") from ${url}"
    curl -sSfL "${url}" -o "${dest}"
    echo "${sha}  ${dest}" | sha256sum -c -
    chmod +x "${dest}"
}

command -v yq       >/dev/null 2>&1 || install_verified \
    "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64" \
    "${BINDIR}/yq" "a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7"
command -v jq       >/dev/null 2>&1 || install_verified \
    "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" \
    "${BINDIR}/jq" "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
command -v envsubst >/dev/null 2>&1 || install_verified \
    "https://github.com/a8m/envsubst/releases/download/v1.4.2/envsubst-Linux-x86_64" \
    "${BINDIR}/envsubst" "a216fad03fb21a5459f57b3e8e02598679229d52e4b24d0c6ed0c46d90d5af3b"

# bats ships no release binary; clone the pinned tag and verify the resulting
# commit SHA (content-addressed) so a re-pointed tag cannot swap the code.
if ! command -v bats >/dev/null 2>&1; then
    echo "Installing bats-core v1.11.1"
    git clone --depth 1 -b v1.11.1 https://github.com/bats-core/bats-core /tmp/bats-core
    bats_sha="$(git -C /tmp/bats-core rev-parse HEAD)"
    if [[ "${bats_sha}" != "b640ec3cf2c7c9cfc9e6351479261186f76eeec8" ]]; then
        echo "ERROR: bats-core commit ${bats_sha} does not match the pinned commit"
        exit 1
    fi
    ln -sf /tmp/bats-core/bin/bats "${BINDIR}/bats"
fi

for tool in oc kubectl git bats yq jq envsubst; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: required tool '${tool}' not found on PATH"; exit 1; }
done

# --- Fetch the operator repo (hosts the runner, setup and manifests) ---------
OPERATOR_DIR="$(mktemp -d /tmp/osc-XXXXXX)"
echo "Cloning ${OPERATOR_REPO} (${OPERATOR_REF})"
git clone --depth 1 -b "${OPERATOR_REF}" "${OPERATOR_REPO}" "${OPERATOR_DIR}"

# --- Run the upstream test runner --------------------------------------------
# The runner writes per-suite JUnit under ${RESULTS_DIR}/<timestamp>/.
RESULTS_DIR="$(mktemp -d /tmp/kata-results-XXXXXX)"
export RESULTS_DIR

RUNNER="${OPERATOR_DIR}/test/e2e/run_upstream_tests.sh"
runner_args=(-t "${TEST_PROFILE}")
[[ -n "${TESTS_REPO}" ]]     && runner_args+=(--tests-repo "${TESTS_REPO}")
[[ -n "${TESTS_REPO_REF}" ]] && runner_args+=(--tests-repo-ref "${TESTS_REPO_REF}")

# Log only non-sensitive metadata: a user-supplied tests-repo URL may embed
# credentials, so never echo the raw runner arguments.
echo "Running runner with profile=${TEST_PROFILE}${TESTS_REPO:+ (custom tests-repo)}${TESTS_REPO_REF:+ (custom tests-repo-ref)}"
rc=0
"${RUNNER}" "${runner_args[@]}" || rc=$?

# --- Publish JUnit so prow indexes the results -------------------------------
shopt -s nullglob
found=0
for xml in "${RESULTS_DIR}"/*/*.xml; do
    found=1
    cp "${xml}" "${ARTIFACT_DIR}/junit_kata_upstream_$(basename "${xml}")"
done
if [[ "${found}" -eq 0 ]]; then
    # An enabled suite that yields no results is a failure: surface it even when
    # the runner itself exited 0, so the step never "passes" silently.
    echo "ERROR: no JUnit files produced under ${RESULTS_DIR}; failing the suite"
    [[ "${rc}" -eq 0 ]] && rc=1
fi

echo "kata-upstream runner exited ${rc}"
exit "${rc}"
