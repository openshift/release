#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

junit="${ARTIFACT_DIR}/junit_quay_standalone_failover.xml"
oplog="${ARTIFACT_DIR}/failover-operations.log"
workdir=""
testcases=""
tests=0
failures=0

xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# record NAME FAILURE [SYSTEM_OUT]: an empty FAILURE is a pass.
record() {
    local name=$1 failure=$2 out=${3:-}

    tests=$(( tests + 1 ))
    testcases+="  <testcase name=\"$(xml_escape <<< "${name}")\">"$'\n'
    if [[ -n "${failure}" ]]; then
        failures=$(( failures + 1 ))
        echo "FAIL: ${name}: ${failure}"
        testcases+="    <failure message=\"$(xml_escape <<< "${failure}")\"/>"$'\n'
    else
        echo "PASS: ${name}"
    fi
    if [[ -n "${out}" ]]; then
        echo "${out}"
        testcases+="    <system-out>$(xml_escape <<< "${out}")</system-out>"$'\n'
    fi
    testcases+="  </testcase>"$'\n'
}

cleanup() {
    local status=$?

    trap - EXIT TERM
    if (( tests > 0 )); then
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="quay-standalone-failover" tests="%d" failures="%d">\n%s</testsuite>\n' \
            "${tests}" "${failures}" "${testcases}" > "${junit}"
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

for command in aws base64 curl jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the failover step image." >&2
        exit 1
    fi
done

for required_file in \
    "${CLUSTER_PROFILE_DIR}/.awscred" \
    "${SHARED_DIR}/quay_standalone_region" \
    "${SHARED_DIR}/quay_standalone_hostname" \
    "${SHARED_DIR}/quay_standalone_target_group_arn" \
    "${SHARED_DIR}/quay_standalone_nodes" \
    "${SHARED_DIR}/quay_standalone_ca.crt" \
    "${SHARED_DIR}/quay_oauth2_token" \
    "${SHARED_DIR}/quay_standalone_smoke_image"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required failover input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

mkdir -p "${ARTIFACT_DIR}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
region=$(<"${SHARED_DIR}/quay_standalone_region")
hostname=$(<"${SHARED_DIR}/quay_standalone_hostname")
target_group_arn=$(<"${SHARED_DIR}/quay_standalone_target_group_arn")
mapfile -t nodes < "${SHARED_DIR}/quay_standalone_nodes"
read -r stop_id _ <<< "${nodes[2]}"
read -r keep_id_1 _ <<< "${nodes[0]}"
read -r keep_id_2 _ <<< "${nodes[1]}"
smoke_image=$(<"${SHARED_DIR}/quay_standalone_smoke_image")
repository="${smoke_image%:*}"
tag="${smoke_image##*:}"

umask 077
workdir=$(mktemp -d /tmp/quay-standalone-failover.XXXXXX)
# Tokens go in header files, never in curl's arguments. Quay takes an OAuth
# token as the password of the $oauthtoken user.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
token=$(<"${SHARED_DIR}/quay_oauth2_token")
printf 'Authorization: Bearer %s\n' "${token}" > "${workdir}/api.header"
# shellcheck disable=SC2016 # $oauthtoken is a literal user name
printf 'Authorization: Basic %s\n' "$(printf '%s:%s' '$oauthtoken' "${token}" | base64 -w 0)" > "${workdir}/basic.header"
unset token
$WAS_TRACING && set -x

curl_options=(-sS --connect-timeout 5 --max-time 15 --cacert "${SHARED_DIR}/quay_standalone_ca.crt")
manifest_types="application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"

# One pass of reads through the NLB: an authenticated API GET of the smoke
# repository, a registry bearer token, and a manifest GET. Sets digest on
# success and error on failure.
digest=""
error=""
read_once() {
    local code

    if ! code=$(curl "${curl_options[@]}" -o /dev/null -w '%{http_code}' -H "@${workdir}/api.header" \
        "https://${hostname}/api/v1/repository/${repository}" 2>/dev/null) || [[ "${code}" != 200 ]]; then
        error="API repository GET failed, HTTP ${code}"
        return 1
    fi
    # jq writes the bearer header itself, so the token never reaches a traced line.
    if ! code=$(curl "${curl_options[@]}" -o "${workdir}/v2-auth.json" -w '%{http_code}' -H "@${workdir}/basic.header" \
        "https://${hostname}/v2/auth?service=${hostname}&scope=repository:${repository}:pull" 2>/dev/null) \
        || [[ "${code}" != 200 ]] \
        || ! jq -er '.token // empty | "Authorization: Bearer \(.)"' "${workdir}/v2-auth.json" \
            > "${workdir}/v2.header" 2>/dev/null; then
        error="registry token GET failed, HTTP ${code}"
        return 1
    fi
    if ! code=$(curl "${curl_options[@]}" -o /dev/null -D "${workdir}/manifest.headers" -w '%{http_code}' \
        -H "@${workdir}/v2.header" -H "Accept: ${manifest_types}" \
        "https://${hostname}/v2/${repository}/manifests/${tag}" 2>/dev/null) || [[ "${code}" != 200 ]]; then
        error="manifest GET failed, HTTP ${code}"
        return 1
    fi
    digest=$(tr -d '\r' < "${workdir}/manifest.headers" \
        | awk 'tolower($1) == "docker-content-digest:" { value = $2 } END { print value }')
    if [[ "${digest}" != sha256:* ]]; then
        error="manifest GET without a Docker-Content-Digest"
        return 1
    fi
}

# Bounded client retries: an operation fails only when all 5 attempts do.
attempt_failures=0
last_failure=0
operate() {
    local attempt

    for attempt in 1 2 3 4 5; do
        if read_once; then
            echo "$(date -u +%FT%TZ) ok ${digest}" >> "${oplog}"
            return 0
        fi
        attempt_failures=$(( attempt_failures + 1 ))
        last_failure=$(date +%s)
        echo "$(date -u +%FT%TZ) attempt ${attempt} failed: ${error}" >> "${oplog}"
        sleep 2
    done
    return 1
}

healthy_count() {
    aws --region "${region}" elbv2 describe-target-health --target-group-arn "${target_group_arn}" \
        --targets "$@" --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
}

if ! operate; then
    record "reads through the NLB before the stop" "${error}; the deploy token is valid for 9000s"
    exit 1
fi
baseline_digest="${digest}"
healthy=$(healthy_count "Id=${keep_id_1}" "Id=${keep_id_2}" "Id=${stop_id}")
if [[ "${healthy}" != 3 ]]; then
    record "reads through the NLB before the stop" "${healthy} of 3 NLB targets healthy before the stop"
    exit 1
fi
record "reads through the NLB before the stop" "" "${repository}:${tag} is ${baseline_digest}"

attempt_failures=0
stop_time=$(date +%s)
aws --region "${region}" ec2 stop-instances --instance-ids "${stop_id}" >/dev/null
echo "Stopped Quay node 3 (${stop_id}); reading through the NLB."
echo "$(date -u +%FT%TZ) stopped ${stop_id}" >> "${oplog}"

left_time=0
operations=0
operation_failures=0
mismatches=0
while true; do
    now=$(date +%s)
    if (( left_time == 0 )); then
        state=$(aws --region "${region}" elbv2 describe-target-health --target-group-arn "${target_group_arn}" \
            --targets "Id=${stop_id}" --query 'TargetHealthDescriptions[0].TargetHealth.State' \
            --output text 2>/dev/null || true)
        if [[ "${state}" =~ ^(unhealthy|unused|draining|unavailable)$ ]]; then
            left_time="${now}"
            echo "Target ${stop_id} is ${state} $(( now - stop_time ))s after the stop."
            echo "$(date -u +%FT%TZ) target ${stop_id} ${state}" >> "${oplog}"
        elif (( now - stop_time >= 300 )); then
            break
        fi
    elif (( now - left_time >= 120 )); then
        break
    fi
    operations=$(( operations + 1 ))
    if ! operate; then
        operation_failures=$(( operation_failures + 1 ))
    elif [[ "${digest}" != "${baseline_digest}" ]]; then
        mismatches=$(( mismatches + 1 ))
        echo "$(date -u +%FT%TZ) digest ${digest} differs from ${baseline_digest}" >> "${oplog}"
    fi
    sleep 1
done

recovery=0
if (( last_failure >= stop_time )); then
    recovery=$(( last_failure - stop_time ))
fi
summary="${operations} operations, ${operation_failures} failed after 5 attempts, ${attempt_failures} failed attempts; last failure ${recovery}s after the stop (recovery time)."

if (( left_time > 0 )); then
    record "stopped node's NLB target leaves healthy within 5m" "" "$(( left_time - stop_time ))s after the stop"
else
    record "stopped node's NLB target leaves healthy within 5m" "target ${stop_id} still healthy 300s after the stop"
fi
if (( operation_failures == 0 )); then
    record "API and manifest reads through the NLB survive the stop" "" "${summary}"
else
    record "API and manifest reads through the NLB survive the stop" "${operation_failures} of ${operations} operations failed" "${summary}"
fi
if (( mismatches == 0 )); then
    record "manifest digest unchanged through failover" ""
else
    record "manifest digest unchanged through failover" "${mismatches} reads returned a digest other than ${baseline_digest}"
fi
healthy=$(healthy_count "Id=${keep_id_1}" "Id=${keep_id_2}")
if [[ "${healthy}" == 2 ]]; then
    record "remaining 2 NLB targets healthy after failover" ""
else
    record "remaining 2 NLB targets healthy after failover" "${healthy} of 2 remaining targets healthy"
fi

echo "${failures} of ${tests} failover checks failed."
if (( failures > 0 )); then
    exit 1
fi
