#!/bin/bash
#
# Run the adversary security scanner against repo source code.
#
# Required env (set by ref YAML defaults):
#   ADVERSARY_SCAN_MODE  -- merge-ref-scan, full-scan, or groundwork
#   CLAUDE_MODEL         -- Claude model for the scan
#   MAX_TURNS            -- max conversation turns
#
# Provided by ci-operator:
#   ARTIFACT_DIR         -- directory for test artifacts (JUnit, logs)
#   SHARED_DIR           -- shared volume between multi-step jobs
#   PULL_BASE_SHA        -- base branch commit (presubmits only)

set -o nounset
set -o errexit
set -o pipefail

echo "=== Adversary Security Scan ==="
echo "Mode: ${ADVERSARY_SCAN_MODE}"
echo "Model: ${CLAUDE_MODEL}"

# -----------------------------------------------------------------------
# Artifact collection — runs on exit regardless of success/failure
# -----------------------------------------------------------------------
copy_artifacts() {
    echo "Copying artifacts..."

    # Groundwork HTML report
    if [[ -f /tmp/groundwork-report.html ]]; then
        cp /tmp/groundwork-report.html "${ARTIFACT_DIR}/adversary-groundwork-report.html"
        echo "Groundwork HTML report copied."
    fi
}
trap copy_artifacts EXIT TERM INT

# -----------------------------------------------------------------------
# Git HTTPS workaround — CI containers lack SSH host keys
# -----------------------------------------------------------------------
git config --global url."https://github.com/".insteadOf "git@github.com:"

# -----------------------------------------------------------------------
# Install the adversary skill from rosa-claude-plugins marketplace
# -----------------------------------------------------------------------
echo ""
echo "=== Installing plugins ==="
claude plugin marketplace add openshift-online/rosa-claude-plugins
claude plugin install security@rosa-claude-plugins
echo "Plugins installed."

# -----------------------------------------------------------------------
# Build the prompt based on scan mode
# -----------------------------------------------------------------------
PROMPT=""

case "${ADVERSARY_SCAN_MODE}" in
    merge-ref-scan)
        if [[ -z "${PULL_BASE_SHA:-}" ]]; then
            echo "WARNING: PULL_BASE_SHA not set — falling back to full-scan mode."
            PROMPT="/adversary"
        else
            echo "Exposing PR changes for diff detection (base: ${PULL_BASE_SHA})..."
            git reset --soft "${PULL_BASE_SHA}"
            PROMPT="/adversary"
        fi
        ;;
    full-scan)
        PROMPT="/adversary"
        ;;
    groundwork)
        PROMPT="/adversary groundwork"
        ;;
    *)
        echo "ERROR: Unknown ADVERSARY_SCAN_MODE: ${ADVERSARY_SCAN_MODE}"
        exit 1
        ;;
esac

echo "Prompt: ${PROMPT}"

# -----------------------------------------------------------------------
# Workaround: --continue + -p is broken (anthropics/claude-code#42376)
# -----------------------------------------------------------------------
export CLAUDE_CODE_ENTRYPOINT=sdk-cli

# -----------------------------------------------------------------------
# Run the adversary scan
# -----------------------------------------------------------------------
echo ""
echo "=== Running adversary scan ==="

SCAN_START=$(date +%s)
EXIT_CODE=0

timeout 10200 claude \
    --model "${CLAUDE_MODEL}" \
    --output-format stream-json \
    --max-turns "${MAX_TURNS}" \
    -p "${PROMPT}" \
    --verbose 2>&1 | tee "${ARTIFACT_DIR}/adversary-scan.log" || EXIT_CODE=$?

SCAN_DURATION=$(( $(date +%s) - SCAN_START ))
echo ""
echo "=== Scan completed in ${SCAN_DURATION}s (exit ${EXIT_CODE}) ==="

# -----------------------------------------------------------------------
# Parse findings and write severity summary to SHARED_DIR
# -----------------------------------------------------------------------
LOG_FILE="${ARTIFACT_DIR}/adversary-scan.log"

CRITICAL=$(grep -c '\[CRITICAL\]' "${LOG_FILE}" 2>/dev/null) || CRITICAL=0
HIGH=$(grep -c '\[HIGH\]' "${LOG_FILE}" 2>/dev/null) || HIGH=0
MEDIUM=$(grep -c '\[MEDIUM\]' "${LOG_FILE}" 2>/dev/null) || MEDIUM=0
LOW=$(grep -c '\[LOW\]' "${LOG_FILE}" 2>/dev/null) || LOW=0

echo "Findings: ${CRITICAL} critical, ${HIGH} high, ${MEDIUM} medium, ${LOW} low"

cat > "${SHARED_DIR}/adversary-findings-summary.txt" <<EOF
CRITICAL=${CRITICAL}
HIGH=${HIGH}
MEDIUM=${MEDIUM}
LOW=${LOW}
SCAN_MODE=${ADVERSARY_SCAN_MODE}
SCAN_DURATION=${SCAN_DURATION}
EOF

touch "${SHARED_DIR}/adversary-scan-completed"

# -----------------------------------------------------------------------
# Write JUnit XML for Prow reporting
# -----------------------------------------------------------------------
JUNIT_FILE="${ARTIFACT_DIR}/junit_adversary.xml"

if [[ "${EXIT_CODE}" -ne 0 ]]; then
    cat > "${JUNIT_FILE}" <<JEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="adversary-scan" tests="1" failures="1" time="${SCAN_DURATION}">
  <testcase name="[sig-security] adversary-scan ${ADVERSARY_SCAN_MODE}" time="${SCAN_DURATION}">
    <failure message="adversary scan failed (exit ${EXIT_CODE})">Scan exited with code ${EXIT_CODE}.</failure>
  </testcase>
</testsuite>
JEOF
else
    cat > "${JUNIT_FILE}" <<JEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="adversary-scan" tests="1" failures="0" time="${SCAN_DURATION}">
  <testcase name="[sig-security] adversary-scan ${ADVERSARY_SCAN_MODE}" time="${SCAN_DURATION}"/>
</testsuite>
JEOF
fi

echo "JUnit XML written to ${JUNIT_FILE}"

if [[ "${EXIT_CODE}" -ne 0 ]]; then
    echo "Adversary scan failed."
    exit 1
fi

echo "Adversary scan complete."
