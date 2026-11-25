#!/bin/bash
# Canary job: runs on each build cluster every hour to verify basic CI health.
# Writes JUnit XML to $ARTIFACTS for Prow/GCS.

set -o nounset
set -o pipefail

rc=0
cases=""

check() {
    local name=$1; shift
    if "$@" &>/dev/null; then
        cases+="  <testcase name=\"${name}\" classname=\"build-farm-canary\"/>\n"
        echo "ok: ${name}"
    else
        cases+="  <testcase name=\"${name}\" classname=\"build-farm-canary\"><failure/></testcase>\n"
        echo "FAIL: ${name}" >&2
        rc=$((rc+1))
    fi
}

http_ok() {
    local url=$1 timeout=${2:-30}
    local s
    s=$(curl -sS ${3:+-k} --max-time "${timeout}" -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null)
    [[ "$s" == "200" || "$s" == "401" ]]
}

# 1. scheduling: reaching this line means a pod was scheduled
cases+="  <testcase name=\"scheduling\" classname=\"build-farm-canary\"/>\n"
echo "ok: scheduling"

# 2. git-clone: prow's clonerefs populates the workdir before our container starts
check git-clone test -d .git

# 3. internal registry (self-signed cert, skip TLS verification)
check internal-registry http_ok https://image-registry.openshift-image-registry.svc:5000/v2/ 15 insecure

# 4. quay.io
check quay-pull http_ok https://quay.io/v2/

mkdir -p "${ARTIFACTS}"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="build-farm-canary" tests="4" failures="%d" errors="0">\n%b</testsuite>\n' \
    "${rc}" "${cases}" > "${ARTIFACTS}/junit_canary.xml"

exit "${rc}"
