#!/bin/bash
# Canary checks run on each build cluster to verify CI health signals:
#   1. scheduling  - job started (trivially true if we're here)
#   2. git-clone   - GitHub reachable; clonerefs populated the working directory
#   3. internal-registry - image-registry.openshift-image-registry.svc:5000 is responding
#   4. quay-pull   - quay.io v2 API is reachable
#
# Results are written as JUnit XML to ${ARTIFACTS} for GCS upload and Prow display.

set -o nounset
set -o pipefail

failures=0

declare -A results
declare -A messages

record() {
    local name=$1 ok=$2 msg=${3:-}
    if [[ "$ok" == "0" ]]; then
        results[$name]=pass
    else
        results[$name]=fail
        messages[$name]=$msg
        ((failures++)) || true
    fi
}

# 1. Scheduling: if this line executes, a pod was scheduled on the cluster.
record scheduling 0

# 2. Git clone: workdir is the release repo cloned from GitHub by the decoration sidecar.
if [[ -d .git ]]; then
    record git-clone 0
else
    record git-clone 1 "working directory not populated; git clone from GitHub may have failed"
fi

# 3. Internal registry: the v2 API should return 200 or 401 (auth required but up).
reg_status=$(curl -ksS --max-time 15 -o /dev/null -w "%{http_code}" \
    https://image-registry.openshift-image-registry.svc:5000/v2/ 2>/dev/null)
if [[ "$reg_status" == "200" || "$reg_status" == "401" ]]; then
    record internal-registry 0
else
    record internal-registry 1 "image-registry returned HTTP ${reg_status:-000}; expected 200 or 401"
fi

# 4. Quay.io: same v2 API check against quay.io.
quay_status=$(curl -sS --max-time 30 -o /dev/null -w "%{http_code}" \
    https://quay.io/v2/ 2>/dev/null)
if [[ "$quay_status" == "200" || "$quay_status" == "401" ]]; then
    record quay-pull 0
else
    record quay-pull 1 "quay.io returned HTTP ${quay_status:-000}; expected 200 or 401"
fi

# Write JUnit XML.
mkdir -p "${ARTIFACTS}"
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuite name=\"build-farm-canary\" tests=\"4\" failures=\"${failures}\" errors=\"0\">"
    for name in scheduling git-clone internal-registry quay-pull; do
        if [[ "${results[$name]}" == "pass" ]]; then
            echo "  <testcase name=\"${name}\" classname=\"build-farm-canary\"/>"
        else
            echo "  <testcase name=\"${name}\" classname=\"build-farm-canary\">"
            echo "    <failure message=\"${messages[$name]:-failed}\"/>"
            echo "  </testcase>"
        fi
    done
    echo "</testsuite>"
} > "${ARTIFACTS}/junit_canary.xml"

if [[ $failures -gt 0 ]]; then
    echo "FAIL: ${failures} check(s) failed" >&2
    exit 1
fi

echo "All canary checks passed"
