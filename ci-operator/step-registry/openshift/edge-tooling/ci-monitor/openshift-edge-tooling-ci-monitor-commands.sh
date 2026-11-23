#!/bin/bash
set -euo pipefail
set +x

echo "=== Edge OCP CI Monitor ==="

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "${WORK_DIR}"' EXIT
MONITOR_DIR="${EDGE_TOOLING_DIR}/edge-ocp-ci-monitor"
REPORT_STEM="edge-ci-monitor-summary"

# Use the SDK in the image for public Prow artifacts and keep its config writable.
export CLOUDSDK_CONFIG="${WORK_DIR}/gcloud"
export CLOUDSDK_AUTH_DISABLE_CREDENTIALS=true

args=(--output "${WORK_DIR}/${REPORT_STEM}.html" --json)
if [[ -n "${MONITOR_VERSIONS}" ]]; then
    args+=(--versions "${MONITOR_VERSIONS}")
fi
if [[ "${SKIP_PROW}" == "true" ]]; then
    args+=(--skip-prow)
fi
if [[ "${WITH_TIMING}" == "true" ]]; then
    args+=(--with-timing)
fi
if [[ -n "${PAYLOAD_COUNT}" ]]; then
    args+=(--payloads "${PAYLOAD_COUNT}")
fi

# The monitor can still generate a dashboard if Chai credentials are unavailable.
CHAI_MCP_TOKEN=$(cat /var/run/chai-bot/mcp-token 2>/dev/null || true)
CHAI_MCP_URL=$(cat /var/run/chai-bot/mcp-url 2>/dev/null || true)

cd "${WORK_DIR}"
MONITOR_EXIT=0
START_SECONDS=${SECONDS}
MONITOR_LOG="${ARTIFACT_DIR}/edge-ci-monitor.log"
# Send stderr to tee for live diagnostics and keep the machine-readable stdout separate.
CHAI_MCP_TOKEN="${CHAI_MCP_TOKEN}" CHAI_MCP_URL="${CHAI_MCP_URL}" PYTHONPATH="${MONITOR_DIR}" \
    python -u -m edge_ocp_ci_monitor "${args[@]}" \
    2>&1 > "${WORK_DIR}/monitor.stdout" | tee "${MONITOR_LOG}" || MONITOR_EXIT=$?
unset CHAI_MCP_TOKEN CHAI_MCP_URL

# Publish any reports generated before the process exited.
for suffix in html json sippy-summary.json; do
    report="${REPORT_STEM}.${suffix}"
    if [[ -s "${report}" ]]; then
        cp "${report}" "${ARTIFACT_DIR}/"
    fi
done
if [[ "${MONITOR_EXIT}" -eq 0 && ! -s "${REPORT_STEM}.html" ]]; then
    echo "Edge OCP CI Monitor finished without a dashboard." >&2
    MONITOR_EXIT=1
fi

FAILURES=0
FAILURE=""
if [[ "${MONITOR_EXIT}" -ne 0 ]]; then
    FAILURES=1
    FAILURE="<failure message=\"Edge OCP CI Monitor failed (exit ${MONITOR_EXIT}). See edge-ci-monitor.log.\"/>"
fi
DURATION=$(( SECONDS - START_SECONDS ))
cat > "${ARTIFACT_DIR}/junit_ci-monitor.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="edge-ci-monitor" tests="1" failures="${FAILURES}" time="${DURATION}">
  <testcase name="[sig-edge-enablement] CI monitor" time="${DURATION}">${FAILURE}</testcase>
</testsuite>
EOF
if [[ "${MONITOR_EXIT}" -ne 0 ]]; then
    exit "${MONITOR_EXIT}"
fi

# Share only the fields Slack uses. The monitor's final status line can also
# include diagnostics, so copy only the status and completed/requested counts.
sed -nE '/^(BLOCKING|INFORMING)\|/p' "${WORK_DIR}/monitor.stdout" \
    | cut -d '|' -f 1-6 | sort -u > "${SHARED_DIR}/failing-jobs.txt"
if [[ -s "${REPORT_STEM}.sippy-summary.json" ]]; then
    cp "${REPORT_STEM}.sippy-summary.json" "${SHARED_DIR}/sippy-summary.json"
fi
sed -nE 's/^[0-9:]+ INFO +edge_ocp_ci_monitor — Chai analysis: (complete|partial|unavailable|not_needed) \(([0-9]+\/[0-9]+) targets\).*/\1 \2/p' \
    "${MONITOR_LOG}" | tail -n 1 > "${SHARED_DIR}/chai-analysis-status.txt"
touch "${SHARED_DIR}/monitor-completed"
