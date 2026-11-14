#!/bin/bash
set -o nounset
# set -o errexit
set -o pipefail

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget --timeout=30 -qO-) || _fURL=(curl --connect-timeout 10 --max-time 30 -fsSL)
        "${_fURL[@]}" \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        trap '
            LP_IO__ET_PPP__NEW_TS_NAME="${LP_QE__CR__TS_NAME__PFX__ACM:+${LP_QE__CR__TS_NAME__PFX__ACM}--}%s" \
                ExitTrap--PostProcessPrep
        ' EXIT
    else
        echo "WARNING: ExitTrap--PostProcessPrep not available, skipping junit remapping" >&2
    fi
fi

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
SKIP_OCP_DEPLOY="false"
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
fi   

export KUBECONFIG=${SHARED_DIR}/kubeconfig

set +x  # Disable tracing to prevent credential leakage in CI logs
# Set the dynamic vars based on provisioned hub cluster.
CYPRESS_OC_CLUSTER_URL=$(oc whoami --show-server)
export CYPRESS_OC_CLUSTER_URL

CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL

CYPRESS_OC_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export CYPRESS_OC_CLUSTER_PASS

# Playwright equivalents (required by start.sh after Cypress→Playwright migration)
# HUB_URL must be the API server URL (start.sh passes it to 'oc login --server').
HUB_URL=$(oc whoami --show-server)
export HUB_URL
# Sanity-check: HUB_URL must point to the API server, not the web console.
# start.sh passes HUB_URL to 'oc login --server'; a console URL would fail
# with "HTML page instead of server URL".  Redact the full value to avoid
# leaking cluster addresses in CI logs.
if [[ "${HUB_URL}" == *"console"* ]]; then
    echo "ERROR: HUB_URL appears to be a console URL, not an API server URL." >&2
    echo "       Expected output of 'oc whoami --show-server', not '--show-console'." >&2
    exit 1
fi
HUB_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
export HUB_PASSWORD
OC_CLUSTER_URL=$(oc whoami --show-server)
export OC_CLUSTER_URL
OC_CLUSTER_PASS=$(cat "${SHARED_DIR}/kubeadmin-password")
export OC_CLUSTER_PASS
export CONSOLE_USERNAME="${CYPRESS_OC_CLUSTER_USER:-kubeadmin}"
export TEST_MODE="${CYPRESS_TEST_MODE:-integration}"
export GREP="${TEST_TAGS:-@ocpInterop}"

# Set the dynamic vars needed to execute application based tests (GitOps, Ansible, ObjectStore, etc.)
ANSIBLE_TOKEN=$(cat $SECRETS_DIR/alc/ansible-token)
export ANSIBLE_TOKEN

CYPRESS_OBJECTSTORE_ACCESS_KEY=$(cat $SECRETS_DIR/alc/objectstore-access-key)
export CYPRESS_OBJECTSTORE_ACCESS_KEY

CYPRESS_OBJECTSTORE_SECRET_KEY=$(cat $SECRETS_DIR/alc/objectstore-secret-key)
export CYPRESS_OBJECTSTORE_SECRET_KEY

GITHUB_PRIVATE_URL=$(cat $SECRETS_DIR/alc/git-url)
export GITHUB_PRIVATE_URL

GITHUB_USER=$(cat $SECRETS_DIR/alc/git-user)
export GITHUB_USER

GITHUB_TOKEN=$(cat $SECRETS_DIR/alc/git-token)
export GITHUB_TOKEN

# collective-ocp-token is optional; the key may not yet be provisioned in the
# acm-qe/alc-credentials vault collection.  Export it when available so the
# test runner can use it, but do not fail the step when it is absent.
if [[ -f "$SECRETS_DIR/alc/collective-ocp-token" ]]; then
    COLLECTIVE_OCP_TOKEN=$(cat "$SECRETS_DIR/alc/collective-ocp-token")
    export COLLECTIVE_OCP_TOKEN
else
    echo "WARNING: collective-ocp-token not found in acm-qe/alc-credentials vault; tests requiring this credential may be skipped" >&2
fi

# run the test execution script
typeset -i _test_rc=0
./start.sh alc || _test_rc=$?
set -x  # Re-enable tracing

# Copy test results (Playwright or legacy Cypress)
for dir in test-results playwright-report ../tests/cypress/results; do
  if [[ -d "$dir" ]]; then
    cp -r "$dir" "$ARTIFACT_DIR/" || true
  fi
done

# INTEROP-9598: assertiveness floor plus carrier guarantee. Playwright's global
# setup can abort before a single spec runs (known cause: the AAP operator
# preflight) and still leave a well-formed zero-test test-results/junit.xml, so
# the step exits green and prow renders nothing. Whenever no runner report
# carries a test case, replace the report with one failing row that names the
# condition and fail the step. The runner's original bytes are kept beside it
# (suffixed, so the EXIT trap merge, which globs *.xml, leaves them alone).
typeset _junit_report="${ARTIFACT_DIR}/test-results/junit.xml"
typeset -i _junit_cases=0
while IFS= read -r -d '' _junit_file; do
    _junit_cases+=$(grep -c '<testcase' "${_junit_file}" || true)
done < <(find "${ARTIFACT_DIR}" -type f -iname 'junit*.xml' -print0 2>/dev/null)

if (( _junit_cases == 0 )); then
    if [[ -f "${_junit_report}" ]]; then
        _junit_condition="the JUnit report declares zero test cases"
        cp -f "${_junit_report}" "${_junit_report}.empty-original" || true
    else
        _junit_condition="the runner wrote no JUnit report"
        mkdir -p "$(dirname "${_junit_report}")"
    fi
    cat > "${_junit_report}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="acm-tests-alc" tests="1" failures="1" errors="0" skipped="0">
  <testcase name="acm-tests-alc: runner asserted nothing" classname="acm-tests-alc">
    <failure message="${_junit_condition}" type="empty-junit-carrier">${_junit_condition}, so this step asserted nothing. Look for the runner abort in the step build log; a known cause is the AAP operator preflight in the runner global setup (INTEROP-9598).</failure>
  </testcase>
</testsuite>
EOF
    echo "ERROR: ${_junit_condition}; failing the step and recording a JUnit row that names it (INTEROP-9598)." >&2
    _test_rc=1
fi

exit "${_test_rc}"
