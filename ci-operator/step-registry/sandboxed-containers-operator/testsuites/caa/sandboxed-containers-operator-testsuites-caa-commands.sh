#!/bin/bash

set -euo pipefail
# No -x: this step only echoes non-sensitive values. It does not print the
# kubeconfig or any credentials. Exit code mirrors the CAA runner.

# Enable-gate: skip-by-default so the suite stays non-blocking in the post chain.
ENABLE="${TESTS_CAA_ENABLE:-false}"

echo "=========================================="
echo "OSC testsuites :: caa (cloud-api-adaptor e2e)"
echo "TESTS_CAA_ENABLE=${ENABLE}"
echo "=========================================="

if [[ "${ENABLE}" != "true" ]]; then
    echo "caa suite disabled (TESTS_CAA_ENABLE=${ENABLE}); exiting 0."
    cat > "${ARTIFACT_DIR}/junit_caa_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="caa" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="caa" classname="osc.testsuites.caa" time="0">
    <skipped message="TESTS_CAA_ENABLE=${ENABLE}"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Gate --------------------------------------------------------------------
# The gate step (test phase) creates ${SHARED_DIR}/testsuites_gate. Skip this
# suite when the file is absent.
if [[ ! -f "${SHARED_DIR}/testsuites_gate" ]]; then
    echo "gate does not exist; skipping caa suite."
    cat > "${ARTIFACT_DIR}/junit_caa_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="caa" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="caa" classname="osc.testsuites.caa" time="0">
    <skipped message="gate does not exist"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Configuration -----------------------------------------------------------
# The CAA test runner lives in the operator repo. We always run it from the
# development branch.
OPERATOR_REPO="https://github.com/openshift/sandboxed-containers-operator"
OPERATOR_REF="devel"

# User-facing parameters (see the ref for defaults/documentation). They follow
# the TESTS_<SUITE_NAME>_<PARAMETER> convention shared by all OSC test suites:
#   TESTS_CAA_PROVIDER -> runner -p/--provider
#   TESTS_CAA_PROFILE  -> runner -t/--test
#   TESTS_CAA_REPO     -> runner --tests-repo
#   TESTS_CAA_REPO_REF -> runner --tests-repo-ref
#   TESTS_CAA_TIMEOUT  -> runner --timeout
# Empty values are omitted so the runner falls back to its own defaults.
PROVIDER="${TESTS_CAA_PROVIDER:-azure}"
PROFILE="${TESTS_CAA_PROFILE:-}"
TESTS_REPO="${TESTS_CAA_REPO:-}"
TESTS_REPO_REF="${TESTS_CAA_REPO_REF:-}"
TIMEOUT="${TESTS_CAA_TIMEOUT:-}"

# --- Provide the tools the runner needs --------------------------------------
# go and git come from the src image; oc is injected via the ref's `cli` field.
# oc is kubectl-compatible; expose it as kubectl since the runner calls kubectl.
# go-junit-report has no bare binary release, so download the pinned release
# tarball and verify its SHA-256 before extracting. (Long term these tools
# should ship in a pre-built image.)
BINDIR="/tmp/bin"
mkdir -p "${BINDIR}"
export PATH="${BINDIR}:${PATH}"
command -v kubectl >/dev/null 2>&1 || ln -sf "$(command -v oc)" "${BINDIR}/kubectl"

# install_verified URL DEST SHA256
install_verified() {
    local url="$1" dest="$2" sha="$3"
    echo "Installing $(basename "${dest}")"
    curl -sSfL "${url}" -o "${dest}"
    echo "${sha}  ${dest}" | sha256sum -c -
    chmod +x "${dest}"
}

# jq is used to parse the cluster-profile Azure service principal JSON.
command -v jq >/dev/null 2>&1 || install_verified \
    "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" \
    "${BINDIR}/jq" "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"

if ! command -v go-junit-report >/dev/null 2>&1; then
    GJR_VERSION="v2.1.0"
    GJR_URL="https://github.com/jstemmer/go-junit-report/releases/download/${GJR_VERSION}/go-junit-report-${GJR_VERSION}-linux-amd64.tar.gz"
    GJR_SHA="d732451fe505862333f3e97e85ab429a69a4ab1a55c6baa387b184db4d714ba8"
    echo "Installing go-junit-report ${GJR_VERSION}"
    tmp_tgz="$(mktemp /tmp/gjr-XXXXXX.tar.gz)"
    curl -sSfL "${GJR_URL}" -o "${tmp_tgz}"
    echo "${GJR_SHA}  ${tmp_tgz}" | sha256sum -c -
    tar -xzf "${tmp_tgz}" -C "${BINDIR}" go-junit-report
    chmod +x "${BINDIR}/go-junit-report"
    rm -f "${tmp_tgz}"
fi

for tool in go oc kubectl git go-junit-report base64 jq; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: required tool '${tool}' not found on PATH"; exit 1; }
done

# The restricted SCC runs the step container as an arbitrary non-root UID, so
# $HOME may be read-only. Point Go's caches and module cache at writable dirs.
# The CAA test tree is not vendored, so allow module download (-mod=mod).
export HOME="/tmp"
export GOCACHE="/tmp/gocache"
export GOMODCACHE="/tmp/gomod"
export GOFLAGS="-mod=mod"

# ci-operator exports KUBECONFIG for the step; fall back to the shared file.
export KUBECONFIG="${KUBECONFIG:-${SHARED_DIR}/kubeconfig}"

# --- Source cloud credentials for the test provisioner (approach 2) ----------
# The CAA test provisioner needs its OWN cloud API client (to verify pod VMs).
# Rather than depend on peer-pods-secret — which in short-lived modes (Azure
# workload identity, AWS STS) holds no usable static secret — source static
# credentials from the ci-operator cluster profile, which is mounted in every
# phase (including post). This makes the suite work regardless of the cluster's
# peer-pods credential mode. run_caa_tests.sh consumes these env vars with
# env-first precedence and derives all non-credential (infra) config from
# peer-pods-cm. Credential values are never echoed.
case "${PROVIDER}" in
    azure)
        sp_file="${CLUSTER_PROFILE_DIR:-}/osServicePrincipal.json"
        if [[ -n "${CLUSTER_PROFILE_DIR:-}" && -f "${sp_file}" ]]; then
            AZURE_CLIENT_ID="$(jq -r '.clientId' "${sp_file}")"
            AZURE_CLIENT_SECRET="$(jq -r '.clientSecret' "${sp_file}")"
            AZURE_TENANT_ID="$(jq -r '.tenantId' "${sp_file}")"
            export AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID
            sub="$(oc -n kube-system get secret azure-credentials -o jsonpath='{.data.azure_subscription_id}' 2>/dev/null | base64 -d 2>/dev/null || true)"
            [[ -n "${sub}" ]] && export AZURE_SUBSCRIPTION_ID="${sub}"
            echo "Sourced Azure service principal from cluster profile (subscription ${AZURE_SUBSCRIPTION_ID:+set})"
        else
            echo "No cluster-profile Azure SP found; runner will fall back to peer-pods-secret."
        fi
        ;;
    aws)
        aws_cred="${CLUSTER_PROFILE_DIR:-}/.awscred"
        if [[ -n "${CLUSTER_PROFILE_DIR:-}" && -f "${aws_cred}" ]]; then
            AWS_ACCESS_KEY_ID="$(awk -F' *= *' '/^aws_access_key_id/{print $2; exit}' "${aws_cred}")"
            AWS_SECRET_ACCESS_KEY="$(awk -F' *= *' '/^aws_secret_access_key/{print $2; exit}' "${aws_cred}")"
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
            echo "Sourced AWS static credentials from cluster profile."
        else
            echo "No cluster-profile AWS credentials found; runner will fall back to peer-pods-secret."
        fi
        ;;
esac

# --- Fetch the operator repo (hosts run_caa_tests.sh) ------------------------
OPERATOR_DIR="$(mktemp -d /tmp/osc-XXXXXX)"
echo "Cloning ${OPERATOR_REPO} (${OPERATOR_REF})"
git clone --depth 1 -b "${OPERATOR_REF}" "${OPERATOR_REPO}" "${OPERATOR_DIR}"

# --- Run the CAA test runner -------------------------------------------------
# The runner writes per-suite JUnit under ${RESULTS_DIR}/<timestamp>/.
RESULTS_DIR="$(mktemp -d /tmp/caa-results-XXXXXX)"
export RESULTS_DIR

RUNNER="${OPERATOR_DIR}/test/e2e/run_caa_tests.sh"
runner_args=(-p "${PROVIDER}")
[[ -n "${PROFILE}" ]]        && runner_args+=(-t "${PROFILE}")
[[ -n "${TIMEOUT}" ]]        && runner_args+=(--timeout "${TIMEOUT}")
[[ -n "${TESTS_REPO}" ]]     && runner_args+=(--tests-repo "${TESTS_REPO}")
[[ -n "${TESTS_REPO_REF}" ]] && runner_args+=(--tests-repo-ref "${TESTS_REPO_REF}")

# Log only non-sensitive metadata: a user-supplied tests-repo URL may embed
# credentials, so never echo the raw runner arguments.
echo "Running runner provider=${PROVIDER} ${TESTS_REPO:+ (custom tests-repo)}${TESTS_REPO_REF:+ (custom tests-repo-ref)}"
rc=0
"${RUNNER}" "${runner_args[@]}" || rc=$?

# --- Publish JUnit so prow indexes the results -------------------------------
shopt -s nullglob
found=0
for xml in "${RESULTS_DIR}"/*/*.xml; do
    found=1
    cp "${xml}" "${ARTIFACT_DIR}/junit_caa_$(basename "${xml}")"
done
if [[ "${found}" -eq 0 ]]; then
    # An enabled suite that yields no results is a failure: surface it even when
    # the runner itself exited 0, so the step never "passes" silently.
    echo "ERROR: no JUnit files produced under ${RESULTS_DIR}; failing the suite"
    find "${RESULTS_DIR}" -type f 2>/dev/null || true
    cat > "${ARTIFACT_DIR}/junit_caa_noresults.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="caa" tests="1" failures="1" errors="0" skipped="0">
  <testcase name="caa" classname="osc.testsuites.caa" time="0">
    <failure message="runner produced no JUnit results"/>
  </testcase>
</testsuite>
EOF
    [[ "${rc}" -eq 0 ]] && rc=1
fi

echo "caa runner exited ${rc}"
exit "${rc}"
