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

QUAY_REGISTRY="${QUAY_ROUTE#https://}"

# Read credentials
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
[[ -z "$QUAY_USERNAME" ]] && { echo "ERROR: No username in quay-qe-quay-secret" >&2; exit 1; }
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)

PASS=0
FAIL=0

run_check() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${name}" >&2
        FAIL=$((FAIL + 1))
    fi
}

# --- Health checks ---

check_http_200() {
    local url="$1"
    shift
    local http_code
    http_code=$(curl -sk "$@" -o /dev/null -w '%{http_code}' --max-time 30 "${url}")
    [[ "${http_code}" == "200" ]]
}

run_check "health/instance returns 200" \
    check_http_200 "${QUAY_ROUTE}/health/instance"

run_check "api/v1/discovery returns 200" \
    check_http_200 "${QUAY_ROUTE}/api/v1/discovery"

# --- Image push and pull ---

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers"

AUTH_JSON="${XDG_RUNTIME_DIR}/containers/auth.json"
oc registry login --registry "${QUAY_REGISTRY}" \
    --auth-basic "${QUAY_USERNAME}:${QUAY_PASSWORD}" \
    --to="${AUTH_JSON}"

SOURCE_IMAGE="registry.access.redhat.com/ubi9/ubi-micro:latest"
DEST_IMAGE="${QUAY_REGISTRY}/${QUAY_USERNAME}/otel-smoke-test:latest"

push_image() {
    oc image mirror --insecure=true -a "${AUTH_JSON}" \
        "${SOURCE_IMAGE}" "${DEST_IMAGE}" \
        --filter-by-os=linux/amd64 --keep-manifest-list=false
}

pull_image() {
    skopeo inspect --tls-verify=false --authfile "${AUTH_JSON}" \
        "docker://${DEST_IMAGE}" > /dev/null
}

run_check "image push to Quay" push_image
run_check "image pull from Quay" pull_image

# --- Results ---

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

# Save Quay pod logs for debugging
oc -n "${NAMESPACE}" logs -l quay-component=quay-app --tail=1000 \
    > "${ARTIFACT_DIR}/quay-app-logs.txt" 2>&1 || true

if [[ "${FAIL}" -gt 0 ]]; then
    echo "OTEL smoke test failed" >&2
    exit 1
fi

echo "OTEL smoke test passed"
