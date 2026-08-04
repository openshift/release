#!/bin/bash
#
# Run adversarial security scanning using the adversary skill.
#
# Required env:
#   CLAUDE_MODEL          -- model for security analysis
#   SCAN_MODE             -- changed-files | full-repo | critical
#
# Optional env:
#   ENABLE_GROUNDWORK     -- enable deep codebase analysis (default: false)
#   MAX_TURNS             -- max conversation turns (default: 50)
#   GITHUB_TOKEN_PATH     -- path to GitHub token for PR commenting

set -o nounset
set -o errexit
set -o pipefail

echo "=== Starting adversary security scan ==="
echo "Model: ${CLAUDE_MODEL}"
echo "Scan mode: ${SCAN_MODE}"
echo "Groundwork: ${ENABLE_GROUNDWORK}"

# Load GitHub token for potential PR commenting
set +x
if [ -f "${GITHUB_TOKEN_PATH:-}" ]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
    echo "GitHub token loaded."
else
    echo "Warning: GitHub token not found. PR commenting disabled."
fi
set -x

# Determine the repository being scanned from environment variables
REPO_NAME="${REPO_NAME:-unknown}"
echo "Scanning repository: ${REPO_NAME}"

# Change to the appropriate workspace directory
# CI operator checks out the source repo to /workspace/<repo-name>
if [ -d "/workspace/${REPO_NAME}" ]; then
    cd "/workspace/${REPO_NAME}"
elif [ -d "/workspace/rosa-hyperfleet" ]; then
    cd "/workspace/rosa-hyperfleet"
else
    echo "ERROR: Could not find repository workspace"
    ls -la /workspace/
    exit 1
fi

# Ensure we're in a git repo for change detection
if [ ! -d .git ]; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

echo "Working directory: $(pwd)"

# Build the prompt based on scan mode
SCAN_PROMPT=""
GROUNDWORK_FLAG=""
if [[ "${ENABLE_GROUNDWORK}" == "true" ]]; then
    GROUNDWORK_FLAG="--groundwork"
fi

case "${SCAN_MODE}" in
    changed-files)
        if [[ -n "${PULL_BASE_SHA:-}" ]]; then
            echo "Detecting changed files from ${PULL_BASE_SHA}...HEAD"
            CHANGED_FILES=$(git diff --name-only "${PULL_BASE_SHA}...HEAD" | tr '\n' ' ')
            if [[ -z "${CHANGED_FILES}" ]]; then
                echo "No files changed. Skipping scan."
                # Create empty JUnit for successful skip
                cat > "${ARTIFACT_DIR}/junit_security-scan.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="security-scan" tests="1" failures="0" time="0">
  <testcase name="[sig-security] No files changed" time="0"/>
</testsuite>
EOF
                exit 0
            fi
            echo "Changed files: ${CHANGED_FILES}"
            SCAN_PROMPT="Run /adversary security scan on the following changed files: ${CHANGED_FILES} ${GROUNDWORK_FLAG}"
        else
            echo "WARNING: PULL_BASE_SHA not set, falling back to full-repo scan"
            SCAN_MODE="full-repo"
            SCAN_PROMPT="/adversary ${GROUNDWORK_FLAG}"
        fi
        ;;
    full-repo)
        echo "Scanning entire repository"
        SCAN_PROMPT="/adversary ${GROUNDWORK_FLAG}"
        ;;
    critical)
        echo "Scanning critical/high-risk files only"
        SCAN_PROMPT="/adversary --scope critical ${GROUNDWORK_FLAG}"
        ;;
    *)
        echo "ERROR: Unknown SCAN_MODE: ${SCAN_MODE}"
        exit 1
        ;;
esac

# Install the security plugin from GitHub
echo ""
echo "=== Installing security plugin ==="
# Add the rosa-claude-plugins marketplace and install the security plugin
claude plugin marketplace add https://github.com/openshift-online/rosa-claude-plugins
claude plugin install security

echo ""
echo "=== Running security scan ==="
ALLOWED_TOOLS="Read Grep Glob Bash WebSearch"
SCAN_START=$(date +%s)
CLAUDE_EXIT=0

# Run the scan
claude \
    --model "${CLAUDE_MODEL}" \
    --permission-mode default \
    --allowedTools "${ALLOWED_TOOLS}" \
    --output-format stream-json \
    --max-turns "${MAX_TURNS}" \
    --verbose \
    -p "${SCAN_PROMPT}" \
    2>&1 | tee "${ARTIFACT_DIR}/adversary-scan.log" || CLAUDE_EXIT=$?

SCAN_DURATION=$(( $(date +%s) - SCAN_START ))

# Copy any generated reports to artifacts
echo ""
echo "=== Collecting artifacts ==="
find . -name "security-report*.html" -exec cp {} "${ARTIFACT_DIR}/" \; || true
find . -name "payload-analysis*.html" -exec cp {} "${ARTIFACT_DIR}/" \; || true
find . -name "*-findings.json" -exec cp {} "${ARTIFACT_DIR}/" \; || true

# Archive Claude session for debugging
CLAUDE_HOME="/home/claude/.claude"
if [[ -d "${CLAUDE_HOME}/projects" ]]; then
    echo "Archiving Claude session..."
    tar -czf "${ARTIFACT_DIR}/claude-sessions.tar.gz" \
        -C "${CLAUDE_HOME}" projects/ 2>/dev/null || true
fi

# Generate JUnit XML
echo ""
echo "=== Generating JUnit XML ==="
JUNIT_FILE="${ARTIFACT_DIR}/junit_security-scan.xml"

# Parse findings from the log (looking for severity markers)
CRITICAL_COUNT=$(grep -c "\[CRITICAL\]" "${ARTIFACT_DIR}/adversary-scan.log" 2>/dev/null || echo "0")
HIGH_COUNT=$(grep -c "\[HIGH\]" "${ARTIFACT_DIR}/adversary-scan.log" 2>/dev/null || echo "0")
MEDIUM_COUNT=$(grep -c "\[MEDIUM\]" "${ARTIFACT_DIR}/adversary-scan.log" 2>/dev/null || echo "0")
LOW_COUNT=$(grep -c "\[LOW\]" "${ARTIFACT_DIR}/adversary-scan.log" 2>/dev/null || echo "0")

TOTAL_FINDINGS=$(( CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT ))
BLOCKING_FINDINGS=$(( CRITICAL_COUNT + HIGH_COUNT ))

echo "Findings: CRITICAL=${CRITICAL_COUNT}, HIGH=${HIGH_COUNT}, MEDIUM=${MEDIUM_COUNT}, LOW=${LOW_COUNT}"

# Determine test outcome
FAILURE_COUNT=0
FAILURE_XML=""

if [[ "${CLAUDE_EXIT}" -ne 0 ]]; then
    FAILURE_COUNT=1
    FAILURE_XML="    <failure message=\"Security scan failed with exit code ${CLAUDE_EXIT}\">The adversary skill encountered an error during execution.</failure>"
elif [[ "${BLOCKING_FINDINGS}" -gt 0 ]]; then
    # NOTE: Change this behavior based on your requirements
    # Currently CRITICAL/HIGH findings cause test failure
    FAILURE_COUNT=1
    FAILURE_XML="    <failure message=\"${BLOCKING_FINDINGS} CRITICAL/HIGH security findings detected\">Found ${CRITICAL_COUNT} CRITICAL and ${HIGH_COUNT} HIGH severity issues. Review the security report in artifacts.</failure>"
fi

cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="security-scan" tests="1" failures="${FAILURE_COUNT}" time="${SCAN_DURATION}">
  <testcase name="[sig-security] adversary scan (${SCAN_MODE})" time="${SCAN_DURATION}">
${FAILURE_XML}
  </testcase>
  <properties>
    <property name="scan_mode" value="${SCAN_MODE}"/>
    <property name="total_findings" value="${TOTAL_FINDINGS}"/>
    <property name="critical_count" value="${CRITICAL_COUNT}"/>
    <property name="high_count" value="${HIGH_COUNT}"/>
    <property name="medium_count" value="${MEDIUM_COUNT}"/>
    <property name="low_count" value="${LOW_COUNT}"/>
  </properties>
</testsuite>
EOF

echo "JUnit XML written to ${JUNIT_FILE}"

if [[ "${FAILURE_COUNT}" -gt 0 ]]; then
    echo ""
    echo "=== Security scan FAILED ==="
    echo "Review the security report in Prow artifacts for details."
    exit 1
fi

echo ""
echo "=== Security scan completed successfully ==="
