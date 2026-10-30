#!/bin/bash
# Run race-enabled frontend integration tests with the local Cosmos emulator.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

PHASE_TIMINGS="${ARTIFACT_DIR}/integration-phase-timings.log"
TIMED_PHASE=""
PHASE_START_SECONDS=0

# Record setup and teardown separately from the runner's envtest and Go phases.
start_phase() {
    TIMED_PHASE="$1"
    PHASE_START_SECONDS=${SECONDS}
    printf '%s phase=%s event=start\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TIMED_PHASE}" | tee -a "${PHASE_TIMINGS}"
}

finish_phase() {
    local status="$1"
    printf '%s phase=%s event=end duration_seconds=%s status=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TIMED_PHASE}" \
        "$((SECONDS - PHASE_START_SECONDS))" "${status}" | tee -a "${PHASE_TIMINGS}"
    TIMED_PHASE=""
}

# Preserve failed setup timing without changing the test command's exit status.
finish_failed_phase() {
    local status=$?
    if [ -n "${TIMED_PHASE}" ]; then
        finish_phase "${status}"
    fi
}
trap finish_failed_phase EXIT

start_phase helpers
export GOPATH=/opt/app-root
export PATH=${PATH}:"${GOPATH}/bin"
export AZURE_TOKEN_CREDENTIALS=prod
command -v gotestsum
command -v setup-envtest
test -n "${ENVTEST_PREBUILT_ASSETS}"
finish_phase 0

start_phase emulator-start
test-integration/hack/start-cosmos-emulator.sh
finish_phase 0

test-integration/hack/test-integration.sh

start_phase emulator-stop
test-integration/hack/stop-cosmos-emulator.sh
finish_phase 0
