#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit

ARTIFACT_DIR="${ARTIFACT_DIR:=/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
JUNIT_FILE="${ARTIFACT_DIR}/junit_quay_interop.xml"
IMAGE_TAG="${BUILD_ID:-$(date +%s)}"

typeset -A testStatus
typeset -A testDuration
typeset -A testFailureMsg
typeset -a allTests=(
    "[sig-interop][Jira:INTEROP][Feature:Quay] Push and pull image via Quay route"
    "[sig-interop][Jira:INTEROP][Feature:Quay] Verify ODF PVC backing Quay storage"
    "[sig-interop][Jira:INTEROP][Feature:Quay] ACS scan of pushed Quay image"
)

for t in "${allTests[@]}"; do
    testStatus["${t}"]="skipped"
    testDuration["${t}"]=0
    testFailureMsg["${t}"]="Test did not run"
done

typeset -i suiteStart=0
suiteStart=$(date +%s)

RecordResult() {
    typeset name="${1}"; shift
    typeset status="${1}"; shift
    typeset msg="${1:-}"; shift || true
    typeset dur="${1:-0}"; shift || true
    testStatus["${name}"]="${status}"
    testDuration["${name}"]="${dur}"
    testFailureMsg["${name}"]="${msg}"
}

# shellcheck disable=SC2329
GenerateJunit() {
    typeset -i total=${#allTests[@]}
    typeset -i failures=0 skipped=0
    typeset -i elapsed=$(( $(date +%s) - suiteStart ))

    for t in "${allTests[@]}"; do
        [[ "${testStatus[${t}]}" == "failed" ]] && failures=$((failures + 1))
        [[ "${testStatus[${t}]}" == "skipped" ]] && skipped=$((skipped + 1))
    done

    cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="interop-tests-opp-quay-smoke" tests="${total}" failures="${failures}" errors="0" skipped="${skipped}" time="${elapsed}">
EOF

    for t in "${allTests[@]}"; do
        typeset escaped_name
        escaped_name=$(printf '%s' "${t}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        typeset escaped_msg
        escaped_msg=$(printf '%s' "${testFailureMsg[${t}]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')

        if [[ "${testStatus[${t}]}" == "failed" ]]; then
            echo "    <testcase name=\"${escaped_name}\" classname=\"interop-tests-opp-quay-smoke\" time=\"${testDuration[${t}]}\"><failure message=\"${escaped_msg}\"><![CDATA[${testFailureMsg[${t}]}]]></failure></testcase>" >> "${JUNIT_FILE}"
        elif [[ "${testStatus[${t}]}" == "skipped" ]]; then
            echo "    <testcase name=\"${escaped_name}\" classname=\"interop-tests-opp-quay-smoke\" time=\"${testDuration[${t}]}\"><skipped message=\"${escaped_msg}\"/></testcase>" >> "${JUNIT_FILE}"
        else
            echo "    <testcase name=\"${escaped_name}\" classname=\"interop-tests-opp-quay-smoke\" time=\"${testDuration[${t}]}\"/>" >> "${JUNIT_FILE}"
        fi
    done

    cat >> "${JUNIT_FILE}" <<EOF
  </testsuite>
</testsuites>
EOF
    cat "${JUNIT_FILE}"
}

trap GenerateJunit EXIT

DiscoverQuay() {
    QUAY_NS=$(oc get quayregistry --all-namespaces -o jsonpath='{.items[0].metadata.namespace}')
    QUAY_REGISTRY=$(oc get quayregistry -n "${QUAY_NS}" -o jsonpath='{.items[0].metadata.name}')
    QUAY_HOST=$(oc get quayregistry -n "${QUAY_NS}" "${QUAY_REGISTRY}" -o jsonpath='{.status.registryEndpoint}')
    QUAY_HOST="${QUAY_HOST#https://}"
    export QUAY_NS QUAY_REGISTRY QUAY_HOST
}

GetQuayAuth() {
    typeset configSecret
    configSecret=$(oc get quayregistry -n "${QUAY_NS}" "${QUAY_REGISTRY}" -o jsonpath='{.spec.configBundleSecret}')
    if [[ -z "${configSecret}" ]]; then
        configSecret="${QUAY_REGISTRY}-config-bundle"
    fi

    QUAY_USER=$(oc get secret -n "${QUAY_NS}" "${configSecret}" -o jsonpath='{.data.SUPER_USER_EMAIL}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "${QUAY_USER}" ]]; then
        QUAY_USER="quayadmin"
    fi
    QUAY_PASSWORD=$(oc get secret -n "${QUAY_NS}" "${configSecret}" -o jsonpath='{.data.SUPER_USER_PASSWORD}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "${QUAY_PASSWORD}" ]]; then
        typeset initSecret="${QUAY_REGISTRY}-init-config-bundle-secret"
        QUAY_PASSWORD=$(oc get secret -n "${QUAY_NS}" "${initSecret}" -o jsonpath='{.data.superuser-password}' 2>/dev/null | base64 -d || echo "")
    fi

    if [[ -z "${QUAY_PASSWORD}" ]]; then
        for secret in $(oc get secrets -n "${QUAY_NS}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i "quay.*config"); do
            QUAY_PASSWORD=$(oc get secret -n "${QUAY_NS}" "${secret}" -o go-template='{{index .data "config.yaml"}}' 2>/dev/null | base64 -d | grep -oP "(?<=SUPER_USER_PASSWORD: ).*" || echo "")
            [[ -n "${QUAY_PASSWORD}" ]] && break
        done
    fi

    export QUAY_USER QUAY_PASSWORD
}

PreflightCheck() {
    if ! curl -sk --connect-timeout 15 "https://${QUAY_HOST}/api/v1/discovery" | grep -qi "quay"; then
        echo "ERROR: Quay route not reachable at ${QUAY_HOST}" >&2
        return 1
    fi
}

CreateTestOrg() {
    typeset token
    token=$(curl -sk -X POST "https://${QUAY_HOST}/api/v1/signin" \
        -H "Content-Type: application/json" \
        -d "{\"user\":\"${QUAY_USER}\",\"pass\":\"${QUAY_PASSWORD}\"}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

    if [[ -z "${token}" ]]; then
        token=$(curl -sk -H "Authorization: Basic $(echo -n "${QUAY_USER}:${QUAY_PASSWORD}" | base64)" \
            "https://${QUAY_HOST}/api/v1/user/" | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")
    fi

    QUAY_TOKEN="${token}"
    export QUAY_TOKEN

    curl -sk -X POST "https://${QUAY_HOST}/api/v1/organization/" \
        -H "Authorization: Bearer ${QUAY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"name":"interop-smoke-test","email":"interop-test@example.com"}' || true
}

################################################################################
# Test Case 1: Push and pull image via Quay route
################################################################################
RunPushPull() {
    typeset testName="[sig-interop][Jira:INTEROP][Feature:Quay] Push and pull image via Quay route"
    typeset -i start elapsed
    start=$(date +%s)

    DiscoverQuay
    GetQuayAuth
    PreflightCheck || { elapsed=$(( $(date +%s) - start )); RecordResult "${testName}" "failed" "Quay route not reachable" "${elapsed}"; return 1; }
    CreateTestOrg

    typeset pushTarget="${QUAY_HOST}/interop-smoke-test/ubi-smoke:${IMAGE_TAG}"
    typeset authFile="/tmp/quay-auth.json"

    cat > "${authFile}" <<EOF
{"auths":{"${QUAY_HOST}":{"auth":"$(echo -n "${QUAY_USER}:${QUAY_PASSWORD}" | base64)"}}}
EOF

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
        "docker://${pushTarget}" >/dev/null 2>&1; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Image not pullable from Quay after push" "${elapsed}"
        return 1
    fi

    elapsed=$(( $(date +%s) - start ))
    RecordResult "${testName}" "passed" "" "${elapsed}"
    return 0
}

################################################################################
# Test Case 2: Verify ODF PVC backing Quay storage
################################################################################
RunOdfPvcCheck() {
    typeset testName="[sig-interop][Jira:INTEROP][Feature:Quay] Verify ODF PVC backing Quay storage"
    typeset -i start elapsed
    start=$(date +%s)

    typeset pvcCount
    pvcCount=$(oc get pvc -n "${QUAY_NS}" -l app=quay -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
print(len(items))
" 2>/dev/null || echo "0")

    if [[ "${pvcCount}" == "0" ]]; then
        pvcCount=$(oc get pvc -n "${QUAY_NS}" -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = [i for i in data.get('items', []) if 'quay' in i['metadata'].get('name','').lower()]
print(len(items))
" 2>/dev/null || echo "0")
    fi

    if [[ "${pvcCount}" == "0" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "No Quay-related PVCs found in ${QUAY_NS}" "${elapsed}"
        return 1
    fi

    typeset unboundPvcs
    unboundPvcs=$(oc get pvc -n "${QUAY_NS}" -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = [i for i in data.get('items', []) if 'quay' in i['metadata'].get('name','').lower()]
unbound = [i['metadata']['name'] for i in items if i['status'].get('phase') != 'Bound']
print(' '.join(unbound))
" 2>/dev/null || echo "")

    if [[ -n "${unboundPvcs}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Unbound PVCs: ${unboundPvcs}" "${elapsed}"
        return 1
    fi

    typeset odfBacked
    odfBacked=$(oc get pvc -n "${QUAY_NS}" -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = [i for i in data.get('items', []) if 'quay' in i['metadata'].get('name','').lower()]
sc_names = set(i['spec'].get('storageClassName','') for i in items)
odf = any('ocs' in s or 'ceph' in s or 'odf' in s for s in sc_names)
print('true' if odf else 'false')
" 2>/dev/null || echo "false")

    if [[ "${odfBacked}" != "true" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Quay PVCs not using ODF/Ceph storage class" "${elapsed}"
        return 1
    fi

    elapsed=$(( $(date +%s) - start ))
    RecordResult "${testName}" "passed" "" "${elapsed}"
    return 0
}

################################################################################
# Test Case 3: ACS scan of pushed Quay image
################################################################################
RunAcsScan() {
    typeset testName="[sig-interop][Jira:INTEROP][Feature:Quay] ACS scan of pushed Quay image"
    typeset -i start elapsed
    start=$(date +%s)

    typeset acsHost acsPassword
    acsHost=$(oc get route -n stackrox central -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [[ -z "${acsHost}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "ACS Central route not found" "${elapsed}"
        return 1
    fi

    acsPassword=$(oc get secret -n stackrox central-htpasswd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "${acsPassword}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "ACS admin password not found" "${elapsed}"
        return 1
    fi

    typeset pushTarget="${QUAY_HOST}/interop-smoke-test/ubi-smoke:${IMAGE_TAG}"
    typeset -i attempts=0 maxAttempts=20

    while (( attempts < maxAttempts )); do
        typeset scanResult
        scanResult=$(curl -sk -u "admin:${acsPassword}" \
            "https://${acsHost}/v1/images?query=Image:${pushTarget}" 2>/dev/null || echo "")

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

        attempts=$((attempts + 1))
        sleep 15
    done

    elapsed=$(( $(date +%s) - start ))
    RecordResult "${testName}" "failed" "ACS did not detect pushed image within 5 minutes" "${elapsed}"
    return 1
}

################################################################################
# Main execution
################################################################################

typeset -i status=0
RunPushPull || status=1
RunOdfPvcCheck || status=1
RunAcsScan || status=1

if [[ "${MAP_TESTS}" == "true" ]]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget --timeout=30 -qO-) || _fURL=(curl --connect-timeout 10 --max-time 30 -fsSL)
        "${_fURL[@]}" \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )" || true
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep || true
    fi
fi

exit "${status}"
