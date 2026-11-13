#!/bin/bash
set -euo pipefail; shopt -s inherit_errexit

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# shellcheck disable=SC2154
_opp_cleanup() {
  _exit_code=$?
  set +x 2>/dev/null
  # Scrub credentials before copying
  sed -i -E \
    -e 's/(password|token|secret|key|credential)=[^ ]*/\1=REDACTED/gi' \
    -e 's/Bearer [A-Za-z0-9._~+\/=-]+/Bearer [REDACTED]/g' \
    -e 's/password=[^ &]+/password=[REDACTED]/g' \
    -e 's/token=[^ &]+/token=[REDACTED]/g' \
    -e 's|://[^:@/]*:[^:@/]*@|://[REDACTED]:[REDACTED]@|g' \
    "${_xtrace_log}" 2>/dev/null || true
  if [[ ${_exit_code} -ne 0 && -n "${ARTIFACT_DIR:-}" ]]; then
    cp "${_xtrace_log}" "${ARTIFACT_DIR}/" 2>/dev/null || true
    echo ">>> TRACE: xtrace log saved to artifacts (exit code ${_exit_code})"
  fi
}
trap '_opp_cleanup' EXIT

echo ">>> PHASE: initialization"

ARTIFACT_DIR="${ARTIFACT_DIR:=/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
# Raw suite name and file name carry the step identity; ExitTrap
# post-processing renames the suite with the template composed below and
# merges this file into junit--interop-quay-smoke-acs-odf-registry.xml.
typeset junitFile="${ARTIFACT_DIR}/junit_interop-quay-smoke-acs-odf-registry.xml"

# Suite naming for the JUnit post-processing library: compose its suite-name
# template from the component-suffixed prefix variable the consuming job sets.
# The step ref declares the prefix with no default on purpose, so a step-local
# value can never pin a prefix the job cannot see. When the prefix is unset
# the raw suite name is kept, so the step still reports, and the gap is called
# out loudly instead of failing the run.
if [[ -n "${LP_QE__CR__TS_NAME__PFX__QUAY:-}" ]]; then
    export LP_IO__ET_PPP__NEW_TS_NAME="${LP_QE__CR__TS_NAME__PFX__QUAY:+${LP_QE__CR__TS_NAME__PFX__QUAY}--}%s"
else
    echo ">>> WARNING: LP_QE__CR__TS_NAME__PFX__QUAY is unset or empty; keeping the raw suite name, which will not route to a component" >&2
    unset LP_IO__ET_PPP__NEW_TS_NAME
fi

typeset imageTag=''
imageTag="${BUILD_ID:-$(date +%s)}"
# Ephemeral ACS admin password file: written once by RunAcsScan inside a
# subshell with xtrace disabled, read by the ACS helpers through
# process-substitution curl configs, removed in Main.
typeset acsPassFile='/tmp/acs-admin-password'

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
  <testsuite name="interop-quay-smoke-acs-odf-registry" tests="${total}" failures="${failures}" errors="0" skipped="${skipped}" time="${elapsed}">
EOF

    for t in "${allTests[@]}"; do
        typeset escapedName=''
        escapedName="$(printf '%s' "${t}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')"
        typeset escapedMsg=''
        escapedMsg="$(printf '%s' "${testFailureMsg[${t}]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')"

        if [[ "${testStatus[${t}]}" == "failed" ]]; then
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-quay-smoke-acs-odf-registry\" time=\"${testDuration[${t}]}\"><failure message=\"${escapedMsg}\"><![CDATA[${testFailureMsg[${t}]}]]></failure></testcase>" >> "${junitFile}"
        elif [[ "${testStatus[${t}]}" == "skipped" ]]; then
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-quay-smoke-acs-odf-registry\" time=\"${testDuration[${t}]}\"><skipped message=\"${escapedMsg}\"/></testcase>" >> "${junitFile}"
        else
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-quay-smoke-acs-odf-registry\" time=\"${testDuration[${t}]}\"/>" >> "${junitFile}"
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
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; || true
}

# Load ExitTrap library for JUnit XML post-processing at script level
# (must be loaded before trap can fire to avoid secondary errors).
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
)"

# Post-process the JUnit XML for Component Readiness routing.  Guarded on
# purpose: this runs from the EXIT trap, and an unloaded helper (download
# failure) or a post-processing failure must not overwrite the script's
# exit status (the unguarded call fails the trap with 127 and turns a
# passing run into a failure).  The merged file name is passed explicitly:
# the library default (jUnit.xml) is not picked up by the prow JUnit viewer
# (lowercase junit prefix required) and collides with other steps in
# shared storage.
PostProcessJunit () {
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        ExitTrap--PostProcessPrep junit--interop-quay-smoke-acs-odf-registry.xml ||
            echo "WARNING: junit post-processing failed" >&2
    else
        echo "WARNING: ExitTrap--PostProcessPrep not available, skipping junit remapping" >&2
    fi
    true
}

trap '_opp_cleanup; GenerateJunit; _propagate_junit; PostProcessJunit' EXIT

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
        echo "ERROR: QuayRegistry ${QUAY_REGISTRY} exists but its registryEndpoint is empty (route not ready)" >&2
        # rc 2: Quay is deployed but not usable: distinct from rc 1 (Quay
        # not deployed), so the caller fails instead of reporting a skip.
        return 2
    fi
    export QUAY_NS QUAY_REGISTRY QUAY_HOST
    true
}

function GetQuayAuth () {
    # Quay credentials are exported for downstream use in the current
    # shell (Best Practices exception for variables needed downstream);
    # xtrace is disabled once for the whole credential flow and restored
    # at the single exit below, instead of toggled around each use.
    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true
    typeset authOk=false
    set +x

    QUAY_USER=""
    QUAY_PASSWORD=""
    QUAY_TOKEN=""

    if oc get secret quayadmin -n "${QUAY_NS}" -o name 1>/dev/null; then
        QUAY_TOKEN="$(oc get secret quayadmin -n "${QUAY_NS}" -o jsonpath='{.data.token}' | base64 -d)" || QUAY_TOKEN=""
        QUAY_PASSWORD="$(oc get secret quayadmin -n "${QUAY_NS}" -o jsonpath='{.data.password}' | base64 -d)" || QUAY_PASSWORD=""
        QUAY_USER="quayadmin"
        if [[ -n "${QUAY_TOKEN}" || -n "${QUAY_PASSWORD}" ]]; then
            authOk=true
            echo "INFO: Quay credentials obtained from quayadmin secret"
        fi
    fi

    if [[ "${authOk}" == false ]]; then
        if oc get secret quaydevel -n "${QUAY_NS}" -o name 1>/dev/null; then
            QUAY_PASSWORD="$(oc get secret quaydevel -n "${QUAY_NS}" -o jsonpath='{.data.password}' | base64 -d)" || QUAY_PASSWORD=""
            QUAY_USER="quaydevel"
            if [[ -n "${QUAY_PASSWORD}" ]]; then
                authOk=true
                echo "INFO: Quay credentials obtained from quaydevel secret"
            fi
        fi
    fi

    if [[ "${authOk}" == false ]]; then
        typeset initPassword=''
        initPassword="$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))")"
        typeset initResult=''
        # The payload is piped in via stdin so the generated password is
        # never part of the curl argv.
        initResult="$(printf '%s' "{\"username\":\"quayadmin\",\"password\":\"${initPassword}\",\"email\":\"quayadmin@example.com\",\"access_token\":true}" | \
            curl -fsSLk --connect-timeout 15 --max-time 60 -X POST "https://${QUAY_HOST}/api/v1/user/initialize" \
                -H "Content-Type: application/json" \
                -d @-)" || initResult=""

        QUAY_TOKEN="$(printf '%s' "${initResult}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)" || QUAY_TOKEN=""
        if [[ -n "${QUAY_TOKEN}" ]]; then
            QUAY_USER="quayadmin"
            QUAY_PASSWORD="${initPassword}"
            authOk=true
            echo "INFO: Quay admin user initialized via /api/v1/user/initialize"
        fi
    fi

    export QUAY_USER QUAY_PASSWORD QUAY_TOKEN
    "${xtraceOn}" && set -x

    if [[ "${authOk}" == true ]]; then
        return 0
    fi
    echo "ERROR: Could not obtain Quay credentials from any source" >&2
    return 1
}

function PreflightCheck () {
    if ! curl -fsSLk --connect-timeout 15 --max-time 30 "https://${QUAY_HOST}/api/v1/discovery" | grep -qi "quay"; then
        echo "ERROR: Quay registry endpoint not reachable" >&2
        return 1
    fi
    true
}

function CreateTestOrg () {
    # Best effort: create the interop-smoke-test organization; re-runs
    # against an existing organization return an HTTP error that must not
    # fail the step, and the push test surfaces a real problem with its
    # own message.  The signin token exchange sets QUAY_TOKEN for
    # downstream use in the current shell (Best Practices exception), so
    # xtrace is disabled once here and restored at the single exit below.
    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true
    set +x

    if [[ -z "${QUAY_TOKEN}" && -n "${QUAY_PASSWORD}" ]]; then
        # Password-only auth: exchange the password for an API token via
        # the signin endpoint.  The payload is piped in via stdin so the
        # password is never part of the curl argv.
        typeset cookieFile='/tmp/quay-cookies.txt'
        typeset csrf=''
        csrf="$(curl -fsSLk --connect-timeout 15 --max-time 30 "https://${QUAY_HOST}/csrf_token" -c "${cookieFile}" | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null)" || csrf=""

        if [[ -n "${csrf}" ]]; then
            typeset signinResult=''
            signinResult="$(python3 -c "
import json, sys
print(json.dumps({'username': sys.argv[1], 'password': sys.argv[2]}))
" "${QUAY_USER}" "${QUAY_PASSWORD}" | curl -fsSLk --connect-timeout 15 --max-time 30 -X POST "https://${QUAY_HOST}/api/v1/signin" \
                -H "Content-Type: application/json" \
                -H "X-CSRF-Token: ${csrf}" \
                -b "${cookieFile}" -c "${cookieFile}" \
                -d @-)" || signinResult=""
            QUAY_TOKEN="$(printf '%s' "${signinResult}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)" || QUAY_TOKEN=""
            export QUAY_TOKEN
        fi
        rm -f "${cookieFile}"
    fi

    if [[ -z "${QUAY_TOKEN}" ]]; then
        echo "WARNING: No Quay token available; org creation may fail" >&2
    fi

    curl -fsSLk --connect-timeout 15 --max-time 60 -X POST "https://${QUAY_HOST}/api/v1/organization/" \
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

    # The credential check and the auth file are handled inside subshells
    # with xtrace disabled (Best Practices secret handling): the values
    # are never expanded in a trace.  skopeo reads the auth file, so no
    # credential appears in the command lines either.
    if ! ( set +x
           [[ -n "${QUAY_TOKEN}" || -n "${QUAY_PASSWORD}" ]]
         ); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "No valid Quay authentication token or password available" "${elapsed}"
        return 1
    fi

    ( set +x
      typeset registryAuth=''
      if [[ -n "${QUAY_TOKEN}" ]]; then
          registryAuth="$(printf '%s' "\$oauthtoken:${QUAY_TOKEN}" | base64 -w0)"
      else
          registryAuth="$(printf '%s' "${QUAY_USER}:${QUAY_PASSWORD}" | base64 -w0)"
      fi
      printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${QUAY_HOST}" "${registryAuth}" >"${authFile}"
    true )

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
    typeset acsHost="${1}"
    # Runs in a subshell with xtrace disabled: the registration payload
    # embeds the Quay credentials, and the ACS admin password is read
    # from the ephemeral file into a process-substitution curl config, so
    # neither appears in a trace or in argv.
    ( set +x
      typeset response=''
      if ! response=$(curl -fsSL "${acsTlsOpts[@]}" --connect-timeout 15 --max-time 60 \
          --config <(printf 'user = "admin:%s"\n' "$(cat "${acsPassFile}")") \
          "https://${acsHost}/v1/imageintegrations"); then
          echo "ERROR: Failed to query ACS image integrations" >&2
          exit 1
      fi

      typeset existing=''
      existing=$(printf '%s' "${response}" | python3 -c "
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
          exit 0
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
      regCode=$(curl -s "${acsTlsOpts[@]}" -o /dev/null -w '%{http_code}' \
          --connect-timeout 15 --max-time 60 \
          -X POST "https://${acsHost}/v1/imageintegrations" \
          --config <(printf 'user = "admin:%s"\n' "$(cat "${acsPassFile}")") \
          -H "Content-Type: application/json" \
          -d "${regPayload}" 2>/dev/null) || regCode="000"
      if [[ "${regCode}" != 2* ]]; then
          echo "ERROR: Failed to register Quay in ACS (HTTP ${regCode})" >&2
          exit 1
      fi

      echo "INFO: Registered Quay as ACS image integration"
    )
}

function RequestAcsScan () {
    typeset acsHost="${1}" imageName="${2}"
    # Runs in a subshell with xtrace disabled; the ACS admin password is
    # read from the ephemeral file into a process-substitution curl
    # config (never in a trace or in argv).
    ( set +x
      typeset scanPayload=''
      scanPayload=$(python3 -c "
import json, sys
payload = {'imageName': sys.argv[1], 'force': True}
print(json.dumps(payload))
" "${imageName}")

      typeset scanCode=""
      scanCode=$(curl -s "${acsTlsOpts[@]}" -o /dev/null -w '%{http_code}' \
          --connect-timeout 15 --max-time 60 \
          -X POST "https://${acsHost}/v1/images/scan" \
          --config <(printf 'user = "admin:%s"\n' "$(cat "${acsPassFile}")") \
          -H "Content-Type: application/json" \
          -d "${scanPayload}" 2>/dev/null) || scanCode="000"
      if [[ "${scanCode}" != 2* ]]; then
          echo "ERROR: ACS scan request failed (HTTP ${scanCode})" >&2
          exit 1
      fi

      echo "INFO: Requested ACS scan for pushed image"
    )
}

function RunAcsScan () {
    typeset testName="[sig-interop][Jira:INTEROP][Feature:Quay] ACS scan of pushed Quay image"
    typeset -i start=0 elapsed=0
    start=$(date +%s)

    typeset acsHost=''
    acsHost="$(oc get route -n stackrox central -o jsonpath='{.spec.host}')" || acsHost=""
    if [[ -z "${acsHost}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "skipped" "ACS not deployed (Central route not found)" "${elapsed}"
        return 0
    fi

    # The ACS admin password is written to an ephemeral file inside a
    # subshell with xtrace disabled (Best Practices secret handling): it
    # is never set as a main-shell variable, never expanded in a trace,
    # and never passed as a command argument.
    ( set +x
      oc get secret -n stackrox central-htpasswd -o jsonpath='{.data.password}' | base64 -d >"${acsPassFile}" || true
    true )
    if [[ ! -s "${acsPassFile}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "skipped" "ACS admin password not available" "${elapsed}"
        return 0
    fi

    typeset pushTarget="${QUAY_HOST}/interop-smoke-test/ubi-smoke:${imageTag}"

    # TLS verification for the ACS Central API: prefer the service CA
    # bundle mounted in the pod (pattern from interop-opp-must-gather-acs);
    # fall back to -k with a warning when the route certificate cannot be
    # verified with it, so an unknown certificate does not hard-fail the
    # test.  Declared here so the helper functions called below (dynamic
    # scoping) share the same options.
    typeset -a acsTlsOpts=( -k )
    typeset saCaBundle='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
    if [[ -f "${saCaBundle}" ]]; then
        typeset tlsProbe=''
        tlsProbe="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 --cacert "${saCaBundle}" "https://${acsHost}/v1/ping")" || tlsProbe='000'
        if [[ -n "${tlsProbe}" && "${tlsProbe}" != '000' ]]; then
            acsTlsOpts=( --cacert "${saCaBundle}" )
        else
            echo "WARNING: ACS route certificate not verifiable with the service CA bundle; falling back to insecure TLS" >&2
        fi
    fi

    if ! RegisterQuayInAcs "${acsHost}"; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to register Quay in ACS" "${elapsed}"
        return 1
    fi
    if ! RequestAcsScan "${acsHost}" "${pushTarget}"; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "ACS scan request failed" "${elapsed}"
        return 1
    fi

    typeset -i attempts=0 maxAttempts=40

    while (( attempts < maxAttempts )); do
        typeset scanResult=''
        scanResult="$(
            set +x
            curl -fsSL "${acsTlsOpts[@]}" --connect-timeout 15 --max-time 30 \
                --config <(printf 'user = "admin:%s"\n' "$(cat "${acsPassFile}")") \
                "https://${acsHost}/v1/images?query=Image:${pushTarget}"
        )" || scanResult=""

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
            RequestAcsScan "${acsHost}" "${pushTarget}" || true
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
            RecordResult "${t}" "failed" "Quay discovery failed (rc=${discoverRc})"
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

    rm -f /tmp/quay-auth.json "${acsPassFile}"

    exit "${status}"
}

Main "$@"

