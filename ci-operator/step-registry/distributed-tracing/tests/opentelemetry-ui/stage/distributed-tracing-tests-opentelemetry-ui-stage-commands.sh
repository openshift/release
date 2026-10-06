#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Runs the OpenShift console UI tests for the OpenTelemetry operator (tests/e2e-otel-ui in the
# MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH branch of openshift/open-telemetry-opentelemetry-operator).
# The step fails when a test fails. The JUnit files, the Playwright
# report, traces and screenshots are written to ARTIFACT_DIR.

# Write a flat context file and the JUnit XMLs to SHARED_DIR so the qe-agent post-step can triage failures.
# SHARED_DIR only supports flat files (no subdirectories), is limited to 1 MiB in total, and must not get
# screenshots, traces or videos: only the JUnit XMLs are copied. The Playwright traces and reports stay in
# the artifacts of this step.
function notify_qe_agent() {
    # The exit status of the step, before anything else runs: the step can fail before any JUnit file exists
    # (a failed clone, a missing password file, the time limit killing Chainsaw).
    local rc=$?
    local has_failures=false
    grep -rqE --include='*.xml' '<(failure|error)[ >]' "${ARTIFACT_DIR}" 2>/dev/null && has_failures=true
    [[ "${rc}" -ne 0 ]] && has_failures=true

    local i=0
    while IFS= read -r xml; do
        if [[ "$(wc -c < "${xml}")" -gt 307200 ]]; then
            echo "Not copying ${xml} to SHARED_DIR: larger than 300 KiB."
            continue
        fi
        cp "${xml}" "${SHARED_DIR}/qe-agent-junit-${i}.xml" 2>/dev/null || true
        i=$((i + 1))
    done < <(find "${ARTIFACT_DIR}" -name "*.xml" 2>/dev/null)

    # The Chainsaw JUnit file only says "exit status 1" for a failed step. The console output of Chainsaw names
    # the step and has what the step printed and the catch operations collected (collector status, pod logs, events).
    if [[ -s "${ARTIFACT_DIR}/chainsaw-output.log" ]]; then
        tail -c 102400 "${ARTIFACT_DIR}/chainsaw-output.log" > "${SHARED_DIR}/qe-agent-ui-chainsaw-output.log" 2>/dev/null || true
    fi

    cat > "${SHARED_DIR}/qe-agent-context.json" <<EOF
{
  "step_script_ref": "distributed-tracing/tests/opentelemetry-ui/stage/distributed-tracing-tests-opentelemetry-ui-stage-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {
    "MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH": "${MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH:-}"
  }
}
EOF
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT

if [[ -z "${MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH:-}" ]]; then
  echo "ERROR: MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH is not set. Provide it via steps.env in the job config or via Gangway API pod_spec_options."
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# The tests need the console: a cluster without it, or an API error, must fail the step and not pass it
# without a test having run.
if ! out="$(oc get clusteroperator console 2>&1)"; then
  echo "Cannot read the console cluster operator, the UI tests cannot run: ${out}"
  exit 1
fi

# Console login: kubeadmin password. ci-operator provides KUBEADMIN_PASSWORD_FILE for IPI clusters; fall back
# to the file that the installer step leaves in SHARED_DIR (also the case for claimed clusters).
if [[ -z "${KUBEADMIN_PASSWORD_FILE:-}" || ! -f "${KUBEADMIN_PASSWORD_FILE}" ]]; then
  if [[ -f "${SHARED_DIR}/kubeadmin-password" ]]; then
    export KUBEADMIN_PASSWORD_FILE="${SHARED_DIR}/kubeadmin-password"
  else
    echo "No kubeadmin password file found (KUBEADMIN_PASSWORD_FILE or ${SHARED_DIR}/kubeadmin-password)."
    exit 1
  fi
fi

BASE_URL="https://$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
export BASE_URL
echo "Console URL: ${BASE_URL}"

# The tests are not part of the image: take them from the product branch under test.
git clone --depth 1 --branch "${MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH}" https://github.com/openshift/open-telemetry-opentelemetry-operator.git /tmp/otel-tests
cd /tmp/otel-tests

# Step pods run as an arbitrary UID whose HOME may be "/": keep every cache in /tmp. Chromium and its libraries
# come from the image.
export HOME=/tmp/home
mkdir -p "${HOME}"
export npm_config_cache=/tmp/npm-cache
export CI=true
export NO_COLOR=1

# The Chainsaw test creates its own namespace and removes it (and the collectors and telemetry generators
# in it) when it is done. It runs Playwright, which writes its JUnit file, report and traces to ARTIFACT_DIR.
# The proxy variables from proxy-conf.sh (sourced above) are picked up by oc and by the Playwright config.
# A hard limit below the step timeout (1h): a hang ends as a normal failure (exit status 124) with the Chainsaw
# output in the artifacts, instead of ci-operator killing the step. The killed run writes no JUnit file, the qe-agent
# context still says has_test_failures=true because of the exit status. With pipefail the exit status is the one
# of chainsaw.
timeout --kill-after=2m 50m chainsaw test --config .chainsaw.yaml \
  --test-dir tests/e2e-otel-ui/collector-dashboard \
  --report-name junit_console_ui_otel_chainsaw --report-path "${ARTIFACT_DIR}" --report-format XML 2>&1 \
  | tee "${ARTIFACT_DIR}/chainsaw-output.log"

echo "OpenTelemetry console UI tests passed."
