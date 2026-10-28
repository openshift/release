#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source_image=docker://quay.io/libpod/busybox:latest
junit="${ARTIFACT_DIR}/junit_quay_standalone_smoke.xml"
workdir=""
testcases=""
tests=0
failures=0

xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

write_junit() {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="quay-standalone-smoke" tests="%d" failures="%d">\n%s</testsuite>\n' \
        "${tests}" "${failures}" "${testcases}" > "${junit}"
}

cleanup() {
    local status=$?

    trap - EXIT TERM
    if (( tests > 0 )); then
        write_junit
    fi
    if [[ -n "${workdir}" ]]; then
        rm -rf -- "${workdir}"
    fi
    exit "${status}"
}

terminate() {
    exit 143
}

trap cleanup EXIT
trap terminate TERM

# Runs one check under errexit in a subshell and records it as a testcase.
check() {
    local name=$1 log start status elapsed

    shift
    log="${workdir}/check.log"
    start=$(date +%s)
    set +o errexit
    ( set -o errexit; "$@" ) > "${log}" 2>&1
    status=$?
    set -o errexit
    elapsed=$(( $(date +%s) - start ))
    tests=$(( tests + 1 ))
    testcases+="  <testcase name=\"$(xml_escape <<< "${name}")\" time=\"${elapsed}\""
    if [[ "${status}" -eq 0 ]]; then
        echo "PASS: ${name}"
        testcases+="/>"$'\n'
    else
        failures=$(( failures + 1 ))
        echo "FAIL: ${name}"
        cat "${log}"
        testcases+=">"$'\n'"    <failure message=\"$(tail -n 1 "${log}" | xml_escape)\">$(xml_escape < "${log}")</failure>"$'\n'"  </testcase>"$'\n'
    fi
}

json_field() {
    node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf8"))[process.argv[1]])' "$1"
}

for command in curl node skopeo; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the smoke step image." >&2
        exit 1
    fi
done

for required_file in \
    /var/run/quay-qe-quay-secret/username \
    /var/run/quay-qe-quay-secret/password \
    "${SHARED_DIR}/quay_standalone_hostname" \
    "${SHARED_DIR}/quay_standalone_nodes" \
    "${SHARED_DIR}/quay_standalone_ca.crt" \
    "${SHARED_DIR}/quay_oauth2_token"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required smoke input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

mkdir -p "${ARTIFACT_DIR}"
umask 077
workdir=$(mktemp -d /tmp/quay-standalone-smoke.XXXXXX)
hostname=$(<"${SHARED_DIR}/quay_standalone_hostname")
username=$(</var/run/quay-qe-quay-secret/username)
mapfile -t nodes < "${SHARED_DIR}/quay_standalone_nodes"
ca="${SHARED_DIR}/quay_standalone_ca.crt"
# skopeo trusts every *.crt in a --cert-dir.
mkdir "${workdir}/certs"
cp "${ca}" "${workdir}/certs/ca.crt"
authfile="${workdir}/auth.json"
repository="${username}/standalone-smoke"
image="${hostname}/${repository}:smoke"

health_nlb() {
    curl -fsS --max-time 30 --cacert "${ca}" -o /dev/null "https://${hostname}/health/instance"
}

health_node() {
    curl -fsS --max-time 30 --cacert "${ca}" --resolve "${hostname}:8443:$1" -o /dev/null \
        "https://${hostname}:8443/health/instance"
}

# The token goes in a header file, never in curl's arguments.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
printf 'Authorization: Bearer %s\n' "$(<"${SHARED_DIR}/quay_oauth2_token")" > "${workdir}/auth.header"
$WAS_TRACING && set -x
api() {
    curl -fsS --max-time 60 --cacert "${ca}" -H "@${workdir}/auth.header" "$@"
}

api_user() {
    local actual

    actual=$(api "https://${hostname}/api/v1/user/" | json_field username)
    if [[ "${actual}" != "${username}" ]]; then
        echo "GET /api/v1/user/ returned user ${actual}, expected ${username}."
        return 1
    fi
}

api_create_repository() {
    node -e 'console.log(JSON.stringify({namespace: process.argv[1], repository: "standalone-smoke",
        visibility: "private", description: "Quay standalone smoke", repo_kind: "image"}))' "${username}" \
        | api -o /dev/null -X POST -H 'Content-Type: application/json' --data-binary @- \
            "https://${hostname}/api/v1/repository"
}

push() {
    skopeo login --cert-dir "${workdir}/certs" --authfile "${authfile}" \
        --username "${username}" --password-stdin "${hostname}" < /var/run/quay-qe-quay-secret/password
    skopeo copy --retry-times 3 --dest-cert-dir "${workdir}/certs" --authfile "${authfile}" \
        --digestfile "${workdir}/pushed.digest" "${source_image}" "docker://${image}"
    echo "Pushed ${image}@$(<"${workdir}/pushed.digest")"
}

pull() {
    skopeo copy --retry-times 3 --src-cert-dir "${workdir}/certs" --authfile "${authfile}" \
        --digestfile "${workdir}/pulled.digest" "docker://${image}" "dir:${workdir}/pulled"
}

digest_matches() {
    local pushed pulled

    pushed=$(<"${workdir}/pushed.digest")
    pulled=$(<"${workdir}/pulled.digest")
    if [[ -z "${pushed}" || "${pushed}" != "${pulled}" ]]; then
        echo "Pulled digest ${pulled} differs from pushed digest ${pushed}."
        return 1
    fi
    echo "Pulled digest equals pushed digest ${pushed}."
}

check "NLB /health/instance over verified TLS" health_nlb
for index in 0 1 2; do
    read -r instance_id public_ip _ <<< "${nodes[${index}]}"
    check "node $((index + 1)) (${instance_id}) /health/instance over verified TLS" health_node "${public_ip}"
done
check "API token authenticates as the initialized user" api_user
check "API creates repository ${repository}" api_create_repository
check "registry push through the NLB" push
check "registry pull through the NLB" pull
check "pulled manifest digest equals pushed digest" digest_matches

if [[ -s "${workdir}/pushed.digest" ]]; then
    printf '%s' "${repository}:smoke" > "${SHARED_DIR}/quay_standalone_smoke_image"
fi

echo "${failures} of ${tests} smoke checks failed."
if (( failures > 0 )); then
    exit 1
fi
