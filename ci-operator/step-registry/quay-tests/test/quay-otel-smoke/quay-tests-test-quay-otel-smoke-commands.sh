#!/bin/bash

set -euo pipefail

NAMESPACE="quay-enterprise"
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

if [[ ! -s "${SHARED_DIR}/quayroute" ]]; then
    echo "ERROR: quayroute not found or empty in SHARED_DIR" >&2
    exit 1
fi
QUAY_ROUTE=$(cat "${SHARED_DIR}/quayroute")
echo "Quay route: ${QUAY_ROUTE}"

OAUTH_TOKEN=$(cat "${SHARED_DIR}/quay_oauth2_token" 2>/dev/null || true)

PASS=0
FAIL=0

check_endpoint() {
    local name="$1"
    local url="$2"
    shift 2

    local http_code
    http_code=$(curl -sk "$@" -o /dev/null -w '%{http_code}' --max-time 30 "${url}")
    if [[ "${http_code}" == "200" ]]; then
        echo "PASS: ${name} returned ${http_code}"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${name} returned ${http_code}" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Health check
check_endpoint "health/instance" "${QUAY_ROUTE}/health/instance"

# API discovery endpoint
check_endpoint "api/v1/discovery" "${QUAY_ROUTE}/api/v1/discovery"

# Authenticated API call (exercises Flask + DB instrumentation)
if [[ -n "${OAUTH_TOKEN}" ]]; then
    check_endpoint "api/v1/superuser/users (authed)" \
        "${QUAY_ROUTE}/api/v1/superuser/users/" \
        -H "Authorization: Bearer ${OAUTH_TOKEN}"
else
    echo "SKIP: No OAuth token available, skipping authenticated API check"
fi

# Check Quay pod logs for OTEL errors
echo ""
echo "Checking Quay pod logs for OTEL initialization errors..."

# Save Quay pod logs for debugging and analysis
if ! oc -n "${NAMESPACE}" logs -l quay-component=quay-app --tail=1000 \
    > "${ARTIFACT_DIR}/quay-app-logs.txt" 2>&1; then
    echo "FAIL: Could not fetch Quay pod logs" >&2
    FAIL=$((FAIL + 1))
else
    OTEL_ERRORS=$(grep -iE "opentelemetry|otel" "${ARTIFACT_DIR}/quay-app-logs.txt" \
        | grep -iE "\b(ERROR|CRITICAL|FATAL)\b|exception|traceback" || true)

    if [[ -n "${OTEL_ERRORS}" ]]; then
        echo "FAIL: OTEL-related errors found in Quay pod logs:" >&2
        echo "${OTEL_ERRORS}" >&2
        FAIL=$((FAIL + 1))
    else
        echo "PASS: No OTEL errors in Quay pod logs"
        PASS=$((PASS + 1))
    fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "${FAIL}" -gt 0 ]]; then
    echo "OTEL smoke test failed" >&2
    exit 1
fi

echo "OTEL smoke test passed"
