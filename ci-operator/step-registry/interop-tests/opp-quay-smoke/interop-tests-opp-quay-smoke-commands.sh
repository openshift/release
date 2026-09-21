#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

ARTIFACT_DIR="${ARTIFACT_DIR:=/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
typeset junitFile="${ARTIFACT_DIR}/junit_quay_interop.xml"
typeset imageTag=''
imageTag="${BUILD_ID:-$(date +%s)}"

typeset -A testStatus=()
typeset -A testDuration=()
typeset -A testFailureMsg=()
typeset -a allTests=(
    "[sig-interop][Jira:INTEROP][Feature:Quay] Push and pull image via Quay route"
    "[sig-interop][Jira:INTEROP][Feature:Quay] Verify ODF object storage integration"
    "[sig-interop][Jira:INTEROP][Feature:Quay] ACS scan of pushed Quay image"
)

for t in "${allTests[@]}"; do
    testStatus["${t}"]="skipped"
    testDuration["${t}"]=0
    testFailureMsg["${t}"]="Test did not run"
done

typeset -i suiteStart=0
suiteStart=$(date +%s)

function RecordResult () {
    typeset name="${1}"; shift
    typeset status="${1}"; shift
    typeset msg="${1:-}"; shift || true
    typeset dur="${1:-0}"; shift || true
    testStatus["${name}"]="${status}"
    testDuration["${name}"]="${dur}"
    testFailureMsg["${name}"]="${msg}"
    true
}

# shellcheck disable=SC2317,SC2329
function GenerateJunit () {
    typeset -i total=${#allTests[@]}
    typeset -i failures=0 skipped=0
    typeset -i elapsed=0
    elapsed=$(( $(date +%s) - suiteStart ))

    for t in "${allTests[@]}"; do
        [[ "${testStatus[${t}]}" == "failed" ]] && failures=$((failures + 1))
        [[ "${testStatus[${t}]}" == "skipped" ]] && skipped=$((skipped + 1))
    done

    cat > "${junitFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="interop-tests-opp-quay-smoke" tests="${total}" failures="${failures}" errors="0" skipped="${skipped}" time="${elapsed}">
EOF

    for t in "${allTests[@]}"; do
        typeset escapedName=''
        escapedName="$(printf '%s' "${t}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')"
        typeset escapedMsg=''
        escapedMsg="$(printf '%s' "${testFailureMsg[${t}]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')"

        if [[ "${testStatus[${t}]}" == "failed" ]]; then
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-tests-opp-quay-smoke\" time=\"${testDuration[${t}]}\"><failure message=\"${escapedMsg}\"><![CDATA[${testFailureMsg[${t}]}]]></failure></testcase>" >> "${junitFile}"
        elif [[ "${testStatus[${t}]}" == "skipped" ]]; then
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-tests-opp-quay-smoke\" time=\"${testDuration[${t}]}\"><skipped message=\"${escapedMsg}\"/></testcase>" >> "${junitFile}"
        else
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-tests-opp-quay-smoke\" time=\"${testDuration[${t}]}\"/>" >> "${junitFile}"
        fi
    done

    cat >> "${junitFile}" <<'EOF'
  </testsuite>
</testsuites>
EOF
    cat "${junitFile}"
    true
}

# shellcheck disable=SC2317
_propagate_junit () {
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
}

trap '{( GenerateJunit; _propagate_junit; true )}' EXIT

function DiscoverQuay () {
    typeset registryJson="" discoverErr=""
    if ! registryJson="$(oc get quayregistry --all-namespaces -o json 2>&1)"; then
        discoverErr="${registryJson}"
        if [[ "${discoverErr}" == *"the server doesn"*"have a resource type"* ]]; then
            echo "INFO: QuayRegistry CRD absent; Quay is not deployed"
            return 1
        fi
        echo "ERROR: Failed to query QuayRegistry: ${discoverErr}" >&2
        return 2
    fi

    typeset itemCount=""
    itemCount="$(printf '%s' "${registryJson}" | python3 -c "
import sys,json
print(len(json.load(sys.stdin).get('items',[])))
")"

    if [[ "${itemCount}" -eq 0 ]]; then
        echo "INFO: No QuayRegistry found; Quay is not deployed"
        return 1
    fi

    QUAY_NS="$(printf '%s' "${registryJson}" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][0]['metadata']['namespace'])")"
    QUAY_REGISTRY="$(oc get quayregistry -n "${QUAY_NS}" -o jsonpath='{.items[0].metadata.name}')"
    QUAY_HOST="$(oc get quayregistry -n "${QUAY_NS}" "${QUAY_REGISTRY}" -o jsonpath='{.status.registryEndpoint}')"
    QUAY_HOST="${QUAY_HOST#https://}"
    if [[ -z "${QUAY_HOST}" ]]; then
        echo "ERROR: Quay registry route not ready (empty host)" >&2
        return 1
    fi
    export QUAY_NS QUAY_REGISTRY QUAY_HOST
    true
}

function GetQuayAuth () {
    QUAY_USER=""
    QUAY_PASSWORD=""
    QUAY_TOKEN=""

    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true
    set +x

    if oc get secret quayadmin -n "${QUAY_NS}" 2>/dev/null; then
        QUAY_TOKEN="$(oc get secret quayadmin -n "${QUAY_NS}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)" || QUAY_TOKEN=""
        QUAY_PASSWORD="$(oc get secret quayadmin -n "${QUAY_NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)" || QUAY_PASSWORD=""
        QUAY_USER="quayadmin"
        if [[ -n "${QUAY_TOKEN}" || -n "${QUAY_PASSWORD}" ]]; then
            "${xtraceOn}" && set -x
            echo "INFO: Quay credentials obtained from quayadmin secret"
            export QUAY_USER QUAY_PASSWORD QUAY_TOKEN
            return 0
        fi
    fi

    if oc get secret quaydevel -n "${QUAY_NS}" 2>/dev/null; then
        QUAY_PASSWORD="$(oc get secret quaydevel -n "${QUAY_NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)" || QUAY_PASSWORD=""
        QUAY_USER="quaydevel"
        if [[ -n "${QUAY_PASSWORD}" ]]; then
            "${xtraceOn}" && set -x
            echo "INFO: Quay credentials obtained from quaydevel secret"
            export QUAY_USER QUAY_PASSWORD QUAY_TOKEN
            return 0
        fi
    fi

    typeset initPassword=''
    initPassword="$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))")"
    typeset initResult=''
    initResult="$(curl -sk --connect-timeout 15 --max-time 60 -X POST "https://${QUAY_HOST}/api/v1/user/initialize" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"quayadmin\",\"password\":\"${initPassword}\",\"email\":\"quayadmin@example.com\",\"access_token\":true}" 2>/dev/null)" || initResult=""

    QUAY_TOKEN="$(echo "${initResult}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)" || QUAY_TOKEN=""
    if [[ -n "${QUAY_TOKEN}" ]]; then
        QUAY_USER="quayadmin"
        QUAY_PASSWORD="${initPassword}"
        "${xtraceOn}" && set -x
        echo "INFO: Quay admin user initialized via /api/v1/user/initialize"
        export QUAY_USER QUAY_PASSWORD QUAY_TOKEN
        return 0
    fi
    "${xtraceOn}" && set -x

    echo "ERROR: Could not obtain Quay credentials from any source" >&2
    export QUAY_USER QUAY_PASSWORD QUAY_TOKEN
    return 1
}

function PreflightCheck () {
    if ! curl -sk --connect-timeout 15 --max-time 30 "https://${QUAY_HOST}/api/v1/discovery" | grep -qi "quay"; then
        echo "ERROR: Quay registry endpoint not reachable" >&2
        return 1
    fi
    true
}

function CreateTestOrg () {
    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true

    if [[ -z "${QUAY_TOKEN}" && -n "${QUAY_PASSWORD}" ]]; then
        typeset cookieFile="/tmp/quay-cookies.txt"
        typeset csrf=''
        csrf="$(curl -sk --connect-timeout 15 --max-time 30 "https://${QUAY_HOST}/csrf_token" -c "${cookieFile}" | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null)" || csrf=""

        if [[ -n "${csrf}" ]]; then
            typeset signinResult=''
            typeset signinPayload=''
            set +x
            signinPayload="$(python3 -c "
import json, sys
print(json.dumps({'username': sys.argv[1], 'password': sys.argv[2]}))
" "${QUAY_USER}" "${QUAY_PASSWORD}")"
            signinResult="$(curl -sk --connect-timeout 15 --max-time 30 -X POST "https://${QUAY_HOST}/api/v1/signin" \
                -H "Content-Type: application/json" \
                -H "X-CSRF-Token: ${csrf}" \
                -b "${cookieFile}" -c "${cookieFile}" \
                -d "${signinPayload}" 2>/dev/null)" || signinResult=""
            QUAY_TOKEN="$(echo "${signinResult}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)" || QUAY_TOKEN=""
            "${xtraceOn}" && set -x
        fi
        rm -f "${cookieFile}"
        export QUAY_TOKEN
    fi

    if [[ -z "${QUAY_TOKEN}" ]]; then
        echo "WARNING: No Quay token available; org creation may fail" >&2
    fi

    set +x
    curl -sk --connect-timeout 15 --max-time 60 -X POST "https://${QUAY_HOST}/api/v1/organization/" \
        -H "Authorization: Bearer ${QUAY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"name":"interop-smoke-test","email":"interop-test@example.com"}' || true
    "${xtraceOn}" && set -x
    true
}

################################################################################
# Test Case 1: Push and pull image via Quay route
################################################################################
function RunPushPull () {
    typeset testName="[sig-interop][Jira:INTEROP][Feature:Quay] Push and pull image via Quay route"
    typeset -i start=0 elapsed=0
    start=$(date +%s)

    typeset pushTarget="${QUAY_HOST}/interop-smoke-test/ubi-smoke:${imageTag}"
    typeset authFile="/tmp/quay-auth.json"

    if [[ -z "${QUAY_TOKEN}" && -z "${QUAY_PASSWORD}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "No valid Quay authentication token or password available" "${elapsed}"
        return 1
    fi

    typeset registryAuth=''
    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true
    set +x
    if [[ -n "${QUAY_TOKEN}" ]]; then
        registryAuth="$(echo -n "\$oauthtoken:${QUAY_TOKEN}" | base64 -w0)"
    else
        registryAuth="$(echo -n "${QUAY_USER}:${QUAY_PASSWORD}" | base64 -w0)"
    fi

    cat > "${authFile}" <<EOF
{"auths":{"${QUAY_HOST}":{"auth":"${registryAuth}"}}}
EOF
    "${xtraceOn}" && set -x

    if ! skopeo copy --dest-tls-verify=false \
        --dest-authfile="${authFile}" \
        docker://registry.access.redhat.com/ubi9-minimal:latest \
        "docker://${pushTarget}" 2>&1; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "skopeo push to Quay failed" "${elapsed}"
        return 1
    fi

    if ! skopeo inspect --tls-verify=false \
        --authfile="${authFile}" \
        "docker://${pushTarget}"; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Image not pullable from Quay after push" "${elapsed}"
        return 1
    fi

    elapsed=$(( $(date +%s) - start ))
    RecordResult "${testName}" "passed" "" "${elapsed}"
    true
}

################################################################################
# Test Case 2: Verify ODF object storage integration
################################################################################
function RunOdfStorageCheck () {
    typeset testName="[sig-interop][Jira:INTEROP][Feature:Quay] Verify ODF object storage integration"
    typeset -i start=0 elapsed=0
    start=$(date +%s)

    typeset noobaaPhase=''
    noobaaPhase="$(oc get noobaa -n openshift-storage -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" || noobaaPhase=""
    if [[ "${noobaaPhase}" != "Ready" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "NooBaa not Ready (phase: ${noobaaPhase:-not found})" "${elapsed}"
        return 1
    fi

    typeset quayObc=''
    quayObc=$(oc get objectbucketclaim -n "${QUAY_NS}" -o json 2>/dev/null | \
        python3 -c "
import sys, json, os
registry = os.environ.get('QUAY_REGISTRY', '')
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['metadata']['name']
    owners = item['metadata'].get('ownerReferences', [])
    if any(o.get('kind') == 'QuayRegistry' for o in owners) or registry in name:
        print(name)
        sys.exit(0)
if data.get('items'):
    print(data['items'][0]['metadata']['name'])
    sys.exit(0)
sys.exit(1)
" 2>/dev/null) || quayObc=""

    if [[ -z "${quayObc}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "No ObjectBucketClaim found in Quay namespace ${QUAY_NS}" "${elapsed}"
        return 1
    fi

    typeset obcPhase=''
    obcPhase=$(oc get objectbucketclaim "${quayObc}" -n "${QUAY_NS}" \
        -o jsonpath='{.status.phase}' 2>/dev/null) || obcPhase=""
    if [[ "${obcPhase}" != "Bound" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Quay OBC ${quayObc} not Bound (phase: ${obcPhase:-unknown})" "${elapsed}"
        return 1
    fi

    typeset obName=''
    obName=$(oc get objectbucket -o json 2>/dev/null | \
        python3 -c "
import sys, json
obc_name, obc_ns = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
for item in data.get('items', []):
    ref = item.get('spec', {}).get('claimRef', {})
    if ref.get('name') == obc_name and ref.get('namespace') == obc_ns:
        print(item['metadata']['name'])
        sys.exit(0)
sys.exit(1)
" "${quayObc}" "${QUAY_NS}" 2>/dev/null) || obName=""

    if [[ -z "${obName}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "No ObjectBucket found for Quay OBC ${quayObc}" "${elapsed}"
        return 1
    fi

    typeset pvcJson=''
    if ! pvcJson=$(oc get pvc -n "${QUAY_NS}" -o json 2>&1); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to list PVCs: ${pvcJson}" "${elapsed}"
        return 1
    fi

    typeset unboundPvcs=''
    unboundPvcs=$(printf '%s' "${pvcJson}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = [i for i in data.get('items', []) if 'quay' in i['metadata'].get('name','').lower()]
unbound = [i['metadata']['name'] for i in items if i.get('status', {}).get('phase') != 'Bound']
print(' '.join(unbound))
") || { elapsed=$(( $(date +%s) - start )); RecordResult "${testName}" "failed" "PVC filter script error" "${elapsed}"; return 1; }

    if [[ -n "${unboundPvcs}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Unbound Quay PVCs: ${unboundPvcs}" "${elapsed}"
        return 1
    fi

    elapsed=$(( $(date +%s) - start ))
    RecordResult "${testName}" "passed" "" "${elapsed}"
    true
}

################################################################################
# Test Case 3: ACS scan of pushed Quay image
################################################################################
function RegisterQuayInAcs () {
    typeset acsHost="${1}" acsPassword="${2}"
    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true
    set +x  # tracing off: credentials

    typeset response=''
    if ! response=$(curl -sk --connect-timeout 15 --max-time 60 -u "admin:${acsPassword}" \
        "https://${acsHost}/v1/imageintegrations" 2>/dev/null); then
        echo "ERROR: Failed to query ACS image integrations" >&2
        "${xtraceOn}" && set -x
        return 1
    fi

    typeset existing=''
    existing=$(echo "${response}" | python3 -c "
import sys, json, os
host = os.environ['QUAY_HOST']
data = json.load(sys.stdin)
for i in data.get('integrations', []):
    if host in i.get('docker', {}).get('endpoint', ''):
        print(i['id'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null) || existing=""

    if [[ -n "${existing}" ]]; then
        echo "INFO: Quay integration already registered in ACS"
        "${xtraceOn}" && set -x
        return 0
    fi

    typeset regUser='' regPass=''
    if [[ -n "${QUAY_TOKEN}" ]]; then
        regUser="\$oauthtoken"
        regPass="${QUAY_TOKEN}"
    else
        regUser="${QUAY_USER}"
        regPass="${QUAY_PASSWORD}"
    fi

    typeset regPayload=''
    regPayload=$(python3 -c "
import json, sys, os
payload = {
    'name': 'interop-quay-smoke',
    'type': 'docker',
    'categories': ['REGISTRY'],
    'docker': {
        'endpoint': os.environ['QUAY_HOST'],
        'username': sys.argv[1],
        'password': sys.argv[2],
        'insecure': True
    },
    'skipTestIntegration': True
}
print(json.dumps(payload))
" "${regUser}" "${regPass}")

    typeset regCode=""
    regCode=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout 15 --max-time 60 \
        -X POST "https://${acsHost}/v1/imageintegrations" \
        -u "admin:${acsPassword}" \
        -H "Content-Type: application/json" \
        -d "${regPayload}" 2>/dev/null) || regCode="000"
    if [[ "${regCode}" != 2* ]]; then
        echo "ERROR: Failed to register Quay in ACS (HTTP ${regCode})" >&2
        "${xtraceOn}" && set -x
        return 1
    fi

    echo "INFO: Registered Quay as ACS image integration"
    "${xtraceOn}" && set -x
    true
}

function RequestAcsScan () {
    typeset acsHost="${1}" acsPassword="${2}" imageName="${3}"
    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true
    set +x  # tracing off: credentials

    typeset scanPayload=''
    scanPayload=$(python3 -c "
import json, sys
payload = {'imageName': sys.argv[1], 'force': True}
print(json.dumps(payload))
" "${imageName}")

    typeset scanCode=""
    scanCode=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout 15 --max-time 60 \
        -X POST "https://${acsHost}/v1/images/scan" \
        -u "admin:${acsPassword}" \
        -H "Content-Type: application/json" \
        -d "${scanPayload}" 2>/dev/null) || scanCode="000"
    if [[ "${scanCode}" != 2* ]]; then
        echo "ERROR: ACS scan request failed (HTTP ${scanCode})" >&2
        "${xtraceOn}" && set -x
        return 1
    fi

    echo "INFO: Requested ACS scan for pushed image"
    "${xtraceOn}" && set -x
    true
}

function RunAcsScan () {
    typeset testName="[sig-interop][Jira:INTEROP][Feature:Quay] ACS scan of pushed Quay image"
    typeset -i start=0 elapsed=0
    start=$(date +%s)

    typeset acsHost='' acsPassword=''
    acsHost="$(oc get route -n stackrox central -o jsonpath='{.spec.host}' 2>/dev/null)" || acsHost=""
    if [[ -z "${acsHost}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "skipped" "ACS not deployed (Central route not found)" "${elapsed}"
        return 0
    fi

    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true
    set +x
    acsPassword="$(oc get secret -n stackrox central-htpasswd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)" || acsPassword=""
    "${xtraceOn}" && set -x
    if [[ -z "${acsPassword}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "skipped" "ACS admin password not available" "${elapsed}"
        return 0
    fi

    typeset pushTarget="${QUAY_HOST}/interop-smoke-test/ubi-smoke:${imageTag}"

    if ! RegisterQuayInAcs "${acsHost}" "${acsPassword}"; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to register Quay in ACS" "${elapsed}"
        return 1
    fi
    if ! RequestAcsScan "${acsHost}" "${acsPassword}" "${pushTarget}"; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "ACS scan request failed" "${elapsed}"
        return 1
    fi

    typeset -i attempts=0 maxAttempts=40

    while (( attempts < maxAttempts )); do
        typeset scanResult=''
        set +x
        scanResult=$(curl -sk --connect-timeout 15 --max-time 30 -u "admin:${acsPassword}" \
            "https://${acsHost}/v1/images?query=Image:${pushTarget}" 2>/dev/null) || scanResult=""
        "${xtraceOn}" && set -x

        if echo "${scanResult}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
images = data.get('images', [])
sys.exit(0 if len(images) > 0 else 1)
" 2>/dev/null; then
            elapsed=$(( $(date +%s) - start ))
            RecordResult "${testName}" "passed" "" "${elapsed}"
            return 0
        fi

        if (( attempts % 4 == 3 )); then
            RequestAcsScan "${acsHost}" "${acsPassword}" "${pushTarget}" || true
        fi

        attempts=$((attempts + 1))
        sleep 15
    done

    elapsed=$(( $(date +%s) - start ))
    RecordResult "${testName}" "failed" "ACS did not detect pushed image within 10 minutes" "${elapsed}"
    return 1
}

################################################################################
# Main execution
################################################################################

function Main () {
    typeset -i discoverRc=0
    DiscoverQuay || discoverRc=$?
    if (( discoverRc == 1 )); then
        for t in "${allTests[@]}"; do
            RecordResult "${t}" "skipped" "Quay not deployed"
        done
        exit 0
    elif (( discoverRc != 0 )); then
        for t in "${allTests[@]}"; do
            RecordResult "${t}" "failed" "QuayRegistry API query failed"
        done
        exit 1
    fi
    if ! GetQuayAuth; then
        for t in "${allTests[@]}"; do
            RecordResult "${t}" "failed" "Quay credential retrieval failed"
        done
        exit 1
    fi
    PreflightCheck || { echo "FATAL: Quay not reachable; skipping all tests" >&2; exit 1; }
    CreateTestOrg

    typeset -i status=0 pushPassed=0
    RunPushPull && pushPassed=1 || status=1
    RunOdfStorageCheck || status=1
    if (( pushPassed )); then
        RunAcsScan || status=1
    else
        RecordResult "[sig-interop][Jira:INTEROP][Feature:Quay] ACS scan of pushed Quay image" "skipped" "Skipped: push-pull test failed; no image available to scan"
    fi

    rm -f /tmp/quay-auth.json

    if [[ "${MAP_TESTS}" == "true" ]]; then
        eval "$(
            typeset -a fetchCmd=()
            type -t wget 1>/dev/null && fetchCmd=(wget --timeout=30 -qO-) || fetchCmd=(curl --connect-timeout 10 --max-time 30 -fsSL)
            "${fetchCmd[@]}" \
                https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
        )" || true
        if type -t ExitTrap--PostProcessPrep; then
            LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
                ExitTrap--PostProcessPrep || true
        fi
    fi

    exit "${status}"
}

Main "$@"

