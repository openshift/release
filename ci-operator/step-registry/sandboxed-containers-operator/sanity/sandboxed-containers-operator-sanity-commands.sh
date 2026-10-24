#!/bin/bash

set -euo pipefail
# No -x: this step only echoes non-sensitive values. It does not print the
# kubeconfig or any credentials. Exit code mirrors the sanity runner.

ENABLE="${SANITY_ENABLE:-false}"

echo "=========================================="
echo "OSC sanity check"
echo "SANITY_ENABLE=${ENABLE}"
echo "=========================================="

if [[ "${ENABLE}" != "true" ]]; then
    echo "sanity check disabled (SANITY_ENABLE=${ENABLE}); exiting 0."
    cat > "${ARTIFACT_DIR}/junit_sanity_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="sanity" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="sanity" classname="osc.sanity" time="0">
    <skipped message="SANITY_ENABLE=${ENABLE}"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Configuration -----------------------------------------------------------
RUNNER_REPO="${SANITY_RUNNER_REPO:-https://github.com/openshift/sandboxed-containers-operator}"
RUNNER_REPO_REF="${SANITY_RUNNER_REPO_REF:-devel}"

# The cluster is not inspected by the runner: it is told what was installed.
# WORKLOAD_TO_TEST and RUNTIMECLASS are the same values the env-cm step records
# in the osc-config config map, so the suite and the installation agree. The
# runner names its workloads the same way, so the value is passed as it is.
WORKLOAD="${WORKLOAD_TO_TEST:-kata}"
case "${WORKLOAD}" in
    kata|peer-pods|coco) ;;
    *)
        echo "ERROR: unsupported WORKLOAD_TO_TEST=${WORKLOAD}"
        exit 1
        ;;
esac
RUNTIME_CLASS="${RUNTIMECLASS:-kata}"

# --- Provide the tools the runner needs ---------------------------------------
# The runner requires: bats oc envsubst. oc is injected via the ref's `cli`
# field; anything still missing is installed on-demand into a writable dir.
# Every downloaded artifact is pinned to a version and verified against a
# recorded SHA-256 to guard against tampering.
BINDIR="/tmp/bin"
mkdir -p "${BINDIR}"
export PATH="${BINDIR}:${PATH}"

# install_verified URL DEST SHA256
install_verified() {
    local url="$1" dest="$2" sha="$3"
    echo "Installing $(basename "${dest}") from ${url}"
    curl -sSfL "${url}" -o "${dest}"
    echo "${sha}  ${dest}" | sha256sum -c -
    chmod +x "${dest}"
}

command -v envsubst >/dev/null 2>&1 || install_verified \
    "https://github.com/a8m/envsubst/releases/download/v1.4.2/envsubst-Linux-x86_64" \
    "${BINDIR}/envsubst" "a216fad03fb21a5459f57b3e8e02598679229d52e4b24d0c6ed0c46d90d5af3b"

# bats ships no release binary; clone the pinned tag and verify the resulting
# commit SHA (content-addressed) so a re-pointed tag cannot swap the code.
# v1.11.1 is recent enough for --report-formatter/--output, added in 1.5.
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

for tool in oc git bats envsubst; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: required tool '${tool}' not found on PATH"; exit 1; }
done

# --- Fetch the runner repo ----------------------------------------------------
# fetch+checkout instead of `clone -b` so SANITY_RUNNER_REPO_REF accepts a
# branch, a tag or a full commit SHA. A user-supplied repo URL may embed
# credentials, so log the ref only, and suppress stderr on fetch: git writes
# the full URL there on failure.
RUNNER_DIR="$(mktemp -d /tmp/osc-XXXXXX)"
echo "Fetching runner repo (ref ${RUNNER_REPO_REF})"
git init -q "${RUNNER_DIR}"
git -C "${RUNNER_DIR}" fetch -q --depth 1 "${RUNNER_REPO}" "${RUNNER_REPO_REF}" 2>/dev/null \
    || git -C "${RUNNER_DIR}" fetch -q "${RUNNER_REPO}" "${RUNNER_REPO_REF}" 2>/dev/null \
    || { echo "ERROR: failed to fetch ref ${RUNNER_REPO_REF}; verify SANITY_RUNNER_REPO and SANITY_RUNNER_REPO_REF"; exit 1; }
git -C "${RUNNER_DIR}" checkout -q FETCH_HEAD
# Record the commit actually used: the default ref tracks a moving branch, so
# this is what tells a later reader whether the runner changed between runs.
echo "Runner commit: $(git -C "${RUNNER_DIR}" rev-parse HEAD)"

RUNNER="${RUNNER_DIR}/test/e2e/run_sanity_tests.sh"
if [[ ! -x "${RUNNER}" ]]; then
    echo "ERROR: test/e2e/run_sanity_tests.sh not found at ref ${RUNNER_REPO_REF}"
    echo "       Set SANITY_RUNNER_REPO_REF to a ref that carries the runner."
    exit 1
fi

# --- Run the sanity check -----------------------------------------------------
runner_args=(--workload "${WORKLOAD}" --runtime_class "${RUNTIME_CLASS}")
[[ -n "${SANITY_TIMEOUT:-}" ]] && runner_args+=(--timeout "${SANITY_TIMEOUT}")

# A confidential containers pod only reaches Trustee if it carries initdata.
# The install-trustee-operator step leaves the initdata it generated in
# ${SHARED_DIR}/INITDATA for the tests to attach to their pods.
if [[ "${WORKLOAD}" == "coco" ]]; then
    if [[ -s "${SHARED_DIR}/INITDATA" ]]; then
        runner_args+=(--initdata "${SHARED_DIR}/INITDATA")
    else
        echo "No initdata in ${SHARED_DIR}/INITDATA: the pod will only reach" \
             "Trustee if peer-pods-cm carries a global INITDATA"
    fi
fi

RESULTS_DIR="$(mktemp -d /tmp/sanity-results-XXXXXX)"
export RESULTS_DIR

echo "Running sanity check: workload=${WORKLOAD} runtime_class=${RUNTIME_CLASS}"
rc=0
"${RUNNER}" "${runner_args[@]}" || rc=$?

# --- Publish the results so prow indexes them ---------------------------------
shopt -s nullglob
found=0
for xml in "${RESULTS_DIR}"/*/*.xml; do
    found=1
    cp "${xml}" "${ARTIFACT_DIR}/junit_sanity_$(basename "${xml}")"
done
# The failure log holds the logs that explain a failure; keep it next to the
# JUnit so the artifacts alone are enough to tell what broke.
for log in "${RESULTS_DIR}"/*/*-failure.log; do
    cp "${log}" "${ARTIFACT_DIR}/sanity_$(basename "${log}")"
done
if [[ "${found}" -eq 0 ]]; then
    # An enabled check that yields no results is a failure: surface it even
    # when the runner itself exited 0, so the step never "passes" silently.
    echo "ERROR: no JUnit files produced under ${RESULTS_DIR}; failing the step"
    [[ "${rc}" -eq 0 ]] && rc=1
fi

echo "sanity runner exited ${rc}"
exit "${rc}"
