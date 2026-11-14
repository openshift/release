#!/bin/bash
set -euo pipefail; shopt -s inherit_errexit

# Restrictive default permissions: the credential files this step writes
# under /tmp are owner-only, whatever the image's default umask was.
umask 077

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# shellcheck disable=SC2154
_opp_cleanup() {
  _exit_code="${1:-0}"
  set +x 2>/dev/null
  # Credential hygiene: these files must not survive the step, on the
  # success and the failure path alike.
  rm -f /tmp/quay-auth.json /tmp/quay-cookies.txt "${acsPassFile:-/tmp/acs-admin-password}" /tmp/acs-ingress-ca.crt /tmp/acs-central-ca.crt
  rm -rf /tmp/quay-ca-candidates
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

# One EXIT trap for the whole run.  The reporting functions are defined
# further down, so every call is guarded on its definition: no window of the
# run is left without cleanup.  errexit is off inside the handler so one
# failing report step cannot skip the rest of the report.
_opp_trap_handler() {
  typeset exitCode=$?
  set +e
  _opp_cleanup "${exitCode}"
  type -t GenerateJunit >/dev/null && GenerateJunit
  type -t _propagate_junit >/dev/null && _propagate_junit
  type -t PostProcessJunit >/dev/null && PostProcessJunit
  true
}
trap '_opp_trap_handler' EXIT

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

# Single source for the row names: the array drives the JUnit report, and the
# recorders below quote the same strings instead of repeating the literals.
typeset testNamePushPull="${allTests[0]}"
typeset testNameOdf="${allTests[1]}"
typeset testNameAcs="${allTests[2]}"

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
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR:-}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; || true
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

function DiscoverQuay () {
    # Branch on API discovery instead of matching the error text: the CRD
    # being absent is an environment limitation, while a failed discovery
    # call is an error that must not read as "Quay is not deployed".
    typeset apiOutput=""
    typeset -i apiRc=0
    apiOutput="$(oc api-resources --api-group=quay.redhat.com 2>&1)" || apiRc=$?
    if (( apiRc != 0 )); then
        echo "ERROR: oc api-resources failed (rc=${apiRc}); cannot determine whether the QuayRegistry CRD is installed: ${apiOutput}" >&2
        return 2
    fi
    if ! grep -qi quayregistry <<< "${apiOutput}"; then
        echo "INFO: QuayRegistry CRD absent; Quay is not deployed"
        return 1
    fi

    typeset registryJson="" discoverErr=""
    if ! registryJson="$(oc get quayregistry --all-namespaces -o json 2>&1)"; then
        discoverErr="${registryJson}"
        echo "ERROR: Failed to query QuayRegistry: ${discoverErr}" >&2
        return 2
    fi

    # The count comes from a helper: a broken or missing helper must fail the
    # step, never compare as zero and read as "Quay is not deployed".
    typeset itemCount=""
    typeset -i countRc=0
    itemCount="$(printf '%s' "${registryJson}" | python3 -c "
import sys,json
print(len(json.load(sys.stdin).get('items',[])))
" 2>&1)" || countRc=$?
    if (( countRc != 0 )) || [[ ! "${itemCount}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Could not count QuayRegistry items (helper exited ${countRc}: ${itemCount})" >&2
        return 2
    fi
    if (( itemCount == 0 )); then
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

# TLS verification for the Quay route: the route certificate is issued by
# the Quay operator's own CA and is not trusted by step pods, so the route
# certificate is resolved from cluster state (route object, operator-owned
# secrets, ingress CA, image trust store) and used as an explicit trust
# anchor for every credential-bearing request; see ResolveQuayTlsTrust.  The
# pushed image is still verified by pulling it back.
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
            curl -fsSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 60 -X POST "https://${QUAY_HOST}/api/v1/user/initialize" \
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

# Quay route TLS trust.  Every credential-bearing request in this step runs
# over a connection whose certificate is verified, so the trust anchor is
# resolved before the first such request.  Only cluster state supplies it: the
# certificate the route publishes for QUAY_HOST, certificates the Quay
# operator owns for this QuayRegistry, the ingress CA, and the image's own
# trust store.  Each candidate is proved against the registry endpoint and the
# first that verifies wins.  There is no -k fallback: when no candidate
# verifies the route, the step fails before a password, token or session
# cookie is sent.
typeset quayCaFile=''
typeset -a quayTlsOpts=()
typeset quayCaDir='/tmp/quay-ca-candidates'

function ResolveQuayTlsTrust () {
    rm -rf "${quayCaDir}"
    mkdir -p "${quayCaDir}"

    # The route that serves QUAY_HOST: a re-encrypt or edge route carries the
    # certificate the cluster publishes for that host.
    typeset routeCert=''
    routeCert="$(oc get routes -n "${QUAY_NS}" -o json 2>/dev/null | \
        QUAY_HOST_NAME="${QUAY_HOST}" python3 -c "
import json, os, sys
try:
    items = json.load(sys.stdin).get('items', [])
except Exception:
    items = []
for r in items:
    if ((r.get('spec') or {}).get('host')) != os.environ['QUAY_HOST_NAME']:
        continue
    sys.stdout.write(((r.get('spec') or {}).get('tls') or {}).get('certificate') or '')
    break
")" || routeCert=''
    if [[ -n "${routeCert}" ]]; then
        printf '%s\n' "${routeCert}" > "${quayCaDir}/10-route.pem"
    fi

    # Certificates the Quay operator publishes for this QuayRegistry: any
    # secret it owns that carries a ca.crt, tls.crt or ssl.cert payload, plus
    # the ssl.cert a Quay configured to serve its own TLS keeps in its config
    # secret.  A Quay that serves its own certificate sits behind a passthrough
    # route, so the route carries no certificate and only these payloads can
    # verify it; each candidate is proved against the endpoint below, so
    # widening the sources cannot admit an anchor that does not fit.
    oc get secrets -n "${QUAY_NS}" -o json 2>/dev/null | \
        QUAY_OWNER="${QUAY_REGISTRY}" CA_DIR="${quayCaDir}" python3 -c "
import base64, json, os, sys

try:
    items = json.load(sys.stdin).get('items', [])
except Exception:
    items = []

owner = os.environ['QUAY_OWNER']
ca_dir = os.environ['CA_DIR']
counts = {'20-owned': 0, '25-ssl': 0}


def write(prefix, payload):
    counts[prefix] += 1
    path = os.path.join(ca_dir, '%s-%02d.pem' % (prefix, counts[prefix]))
    with open(path, 'wb') as fh:
        fh.write(payload)


for s in items:
    refs = (s.get('metadata') or {}).get('ownerReferences') or []
    owned = any((r.get('name') or '') == owner for r in refs)
    data = s.get('data') or {}
    if not owned:
        if data.get('ssl.cert'):
            write('25-ssl', base64.b64decode(data['ssl.cert']))
        continue
    for key in ('ca.crt', 'tls.crt'):
        if data.get(key):
            write('20-owned', base64.b64decode(data[key]))
    if data.get('ssl.cert'):
        write('25-ssl', base64.b64decode(data['ssl.cert']))
" || true

    # The ingress CA signs route certificates that no operator issued.
    typeset ingressCa=''
    ingressCa="$(oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null)" || ingressCa=''
    if [[ -n "${ingressCa}" ]]; then
        printf '%s\n' "${ingressCa}" > "${quayCaDir}/30-ingress.pem"
    fi

    # The image trust store covers a route with a publicly trusted
    # certificate.
    typeset systemBundle=''
    for systemBundle in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
        if [[ -f "${systemBundle}" ]]; then
            cp "${systemBundle}" "${quayCaDir}/40-system.pem"
            break
        fi
    done

    typeset candidate=''
    typeset probe=''
    for candidate in "${quayCaDir}"/*.pem; do
        [[ -f "${candidate}" ]] || continue
        probe="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 --cacert "${candidate}" "https://${QUAY_HOST}/v2/")" || probe='000'
        if [[ -n "${probe}" && "${probe}" != '000' ]]; then
            quayCaFile="${candidate}"
            break
        fi
    done
    if [[ -z "${quayCaFile}" ]]; then
        echo "ERROR: no cluster-published certificate verifies the Quay route at ${QUAY_HOST}; refusing to send credentials over unverified TLS" >&2
        return 1
    fi
    quayTlsOpts=( --cacert "${quayCaFile}" )
    echo "INFO: Quay route TLS verified against ${quayCaFile}"
    return 0
}

function PreflightCheck () {
    # Capture the body first, then grep: grep -q closes the pipe on the
    # first match while curl (streaming, --max-time 30) can still be
    # writing, so a direct `curl | grep -q` can fail the pipeline on
    # SIGPIPE under pipefail even when the endpoint answered (the
    # INTEROP-9670 hazard class, fixed repo-wide for `jq | head`).
    typeset probe=''
    if ! probe="$(curl -fsSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 "https://${QUAY_HOST}/api/v1/discovery")" \
        || ! grep -qi "quay" <<< "${probe}"; then
        echo "ERROR: Quay registry endpoint not reachable" >&2
        return 1
    fi
    true
}

function CreateTestOrg () {
    # Creates the interop-smoke-test organization the push test writes to.
    # A re-run against an existing organization answers with an HTTP error and
    # that does not fail the step, because the organization the push needs is
    # there; every other failure is recorded and reported.  The signin token
    # exchange sets QUAY_TOKEN for downstream use in the current shell (Best
    # Practices exception), so xtrace is disabled once here and restored at
    # each exit below.
    typeset xtraceOn=false
    [[ "${-}" == *x* ]] && xtraceOn=true
    set +x

    # The signin session (cookie jar plus CSRF token) is what authenticates
    # the organization request below, so both outlive the block that creates
    # them and are removed at the single exit of this function.
    typeset cookieFile='/tmp/quay-cookies.txt'
    typeset csrf=''

    if [[ -z "${QUAY_TOKEN}" && -n "${QUAY_PASSWORD}" ]]; then
        # Password-only auth: exchange the password for a session via the
        # signin endpoint.  The payload is piped in via stdin so the
        # password is never part of the curl argv.
        csrf="$(curl -fsSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 "https://${QUAY_HOST}/csrf_token" -c "${cookieFile}" | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null)" || csrf=""

        if [[ -n "${csrf}" ]]; then
            typeset signinResult=''
            # The payload is built inside the helper from the environment
            # (the variables are exported above), and piped in via stdin, so
            # the password appears in neither the helper's argv nor the curl
            # command line.
            signinResult="$(python3 -c "
import json, os
print(json.dumps({'username': os.environ['QUAY_USER'], 'password': os.environ['QUAY_PASSWORD']}))
" | curl -fsSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 -X POST "https://${QUAY_HOST}/api/v1/signin" \
                -H "Content-Type: application/json" \
                -H "X-CSRF-Token: ${csrf}" \
                -b "${cookieFile}" -c "${cookieFile}" \
                -d @-)" || signinResult=""
            # /api/v1/signin answers {"success": true} and sets the session
            # cookie; it does not return a token.  Read the success flag too,
            # and keep the cookie jar for the organization request.
            QUAY_TOKEN="$(printf '%s' "${signinResult}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)" || QUAY_TOKEN=""
            export QUAY_TOKEN
            typeset signinOk=''
            signinOk="$(printf '%s' "${signinResult}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)" || signinOk=""
            if [[ "${signinOk}" == "True" ]]; then
                # Signin rotates the session CSRF token (Quay replaces it from
                # common_login), so the token read before signin is stale: the
                # organization request below would be rejected with HTTP 403
                # and the push would run without an organization.  Read the
                # token that belongs to the session signin just created, over
                # the same cookie jar, and send that one.
                csrf="$(curl -fsSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 \
                    -b "${cookieFile}" -c "${cookieFile}" \
                    "https://${QUAY_HOST}/csrf_token" | \
                    python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null)" || csrf=""
                if [[ -z "${csrf}" ]]; then
                    echo "ERROR: the CSRF token refresh after signin returned no token; skipping the organization request" >&2
                    RecordResult "${testNamePushPull}" "failed" "Could not refresh the Quay CSRF token after signin; the organization request would send a stale token" "0"
                    rm -f "${cookieFile}"
                    "${xtraceOn}" && set -x
                    return 1
                fi
            else
                echo "WARNING: Quay signin did not report success; the organization request has no session to use" >&2
            fi
        fi
    fi

    if [[ -z "${QUAY_TOKEN}" ]]; then
        echo "WARNING: No Quay token available; org creation may fail" >&2
    fi

    typeset -a orgPayloadOpts=( -H "Content-Type: application/json"
        -d '{"name":"interop-smoke-test","email":"interop-test@example.com"}' )
    # The organization request is reported, not swallowed: the response body
    # and the HTTP status are both kept, so a rejected request cannot continue
    # as a success and leave the push lane without an organization.  The body
    # of a rejected request is what names the rejection, so this request does
    # not use -f: the status is appended with -w and split off instead.
    typeset orgRaw=''
    typeset orgResponse=''
    typeset orgHttp='000'
    typeset -i orgRc=0
    if [[ -z "${QUAY_TOKEN}" && -f "${cookieFile}" && -n "${csrf}" ]]; then
        # Password-only signin produced a session, not a token: send the
        # session cookie and the CSRF token refreshed for that session,
        # otherwise this request goes out with an empty bearer header and the
        # push below has no organization.
        orgRaw="$(curl -sSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 60 -X POST \
            -w '\n%{http_code}' \
            "https://${QUAY_HOST}/api/v1/organization/" \
            -b "${cookieFile}" \
            -H "X-CSRF-Token: ${csrf}" \
            "${orgPayloadOpts[@]}" 2>/dev/null)" || orgRc=$?
    else
        # The bearer token is handed to curl through a process-substitution
        # config, so it never appears in the curl argv.
        orgRaw="$(curl -sSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 60 -X POST \
            -w '\n%{http_code}' \
            "https://${QUAY_HOST}/api/v1/organization/" \
            --config <(printf 'header = "Authorization: Bearer %s"\n' "${QUAY_TOKEN}") \
            "${orgPayloadOpts[@]}" 2>/dev/null)" || orgRc=$?
    fi
    typeset -a orgRawLines=()
    mapfile -t orgRawLines <<< "${orgRaw}"
    typeset -i orgLineCount=${#orgRawLines[@]}
    if (( orgLineCount > 0 )) && [[ "${orgRawLines[orgLineCount-1]}" =~ ^[0-9]{3}$ ]]; then
        orgHttp="${orgRawLines[orgLineCount-1]}"
        orgResponse="$(printf '%s\n' "${orgRawLines[@]:0:orgLineCount-1}")"
    else
        orgResponse="${orgRaw}"
    fi

    typeset orgSuccess=''
    orgSuccess="$(printf '%s' "${orgResponse}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)" || orgSuccess=''
    if (( orgRc != 0 )) || [[ ! "${orgHttp}" =~ ^2[0-9]{2}$ ]] || [[ "${orgSuccess}" != "True" ]]; then
        # A re-run against an existing organization answers with an HTTP
        # error, and that must not fail the step: the organization the push
        # needs is already there.  Read it back instead of matching error
        # text, so only a genuinely missing organization is reported.
        typeset orgPresentHttp=''
        if [[ -z "${QUAY_TOKEN}" && -f "${cookieFile}" && -n "${csrf}" ]]; then
            orgPresentHttp="$(curl -sSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 -o /dev/null \
                -w '%{http_code}' \
                -b "${cookieFile}" \
                "https://${QUAY_HOST}/api/v1/organization/interop-smoke-test" 2>/dev/null)" || orgPresentHttp=''
        else
            orgPresentHttp="$(curl -sSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 -o /dev/null \
                -w '%{http_code}' \
                --config <(printf 'header = "Authorization: Bearer %s"\n' "${QUAY_TOKEN}") \
                "https://${QUAY_HOST}/api/v1/organization/interop-smoke-test" 2>/dev/null)" || orgPresentHttp=''
        fi
        if [[ "${orgPresentHttp}" != "200" ]]; then
            typeset orgError=''
            orgError="$(printf '%s' "${orgResponse}" | \
                python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error') or d.get('error_message') or d.get('message') or '')" 2>/dev/null)" || orgError=''
            echo "ERROR: organization creation failed (http ${orgHttp}, curl rc=${orgRc}${orgError:+: ${orgError}}); the push test has no organization" >&2
            RecordResult "${testNamePushPull}" "failed" "Could not create the interop-smoke-test organization (http ${orgHttp}, curl rc=${orgRc}): ${orgError:-the response carried no error field}" "0"
            rm -f "${cookieFile}"
            "${xtraceOn}" && set -x
            return 1
        fi
        echo "INFO: organization interop-smoke-test already exists; continuing without creating it" >&2
    fi
    rm -f "${cookieFile}"

    "${xtraceOn}" && set -x
    true
}

################################################################################
# Test Case 1: Push and pull image via Quay route
################################################################################
function RunPushPull () {
    typeset testName="${testNamePushPull}"
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

    if ! SSL_CERT_FILE="${quayCaFile}" skopeo copy --dest-tls-verify=true \
        --dest-authfile="${authFile}" \
        docker://registry.access.redhat.com/ubi9-minimal:latest \
        "docker://${pushTarget}" 2>&1; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "skopeo push to Quay failed" "${elapsed}"
        return 1
    fi

    # A pull has to read the layers, not only the manifest and config:
    # `skopeo inspect` stops at the manifest, so a registry that serves
    # manifests but cannot return a layer blob from object storage would
    # still pass.  Copy the image into a local dir transport instead.
    typeset pullDir='/tmp/quay-pull-verify'
    rm -rf "${pullDir}"
    if ! SSL_CERT_FILE="${quayCaFile}" skopeo copy --src-tls-verify=true \
        --src-authfile="${authFile}" \
        "docker://${pushTarget}" \
        "dir:${pullDir}"; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Image layers not pullable from Quay after push" "${elapsed}"
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
    typeset testName="${testNameOdf}"
    typeset -i start=0 elapsed=0
    start=$(date +%s)

    # Both readiness checks below are waits, not samples: a fresh ODF install
    # answers the first query long before NooBaa reports Ready or the Quay OBC
    # binds.
    if ! oc wait noobaa/noobaa -n openshift-storage \
        --for=jsonpath='{.status.phase}'=Ready --timeout=10m; then
        typeset noobaaPhase=''
        noobaaPhase=$(oc get noobaa noobaa -n openshift-storage \
            -o jsonpath='{.status.phase}' 2>&1) || noobaaPhase="unknown"
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "NooBaa noobaa in namespace openshift-storage did not reach phase Ready within 10 minutes (observed phase: ${noobaaPhase:-not set})" "${elapsed}"
        return 1
    fi

    typeset obcJson=''
    if ! obcJson=$(oc get objectbucketclaim -n "${QUAY_NS}" -o json 2>&1); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to list ObjectBucketClaims in namespace ${QUAY_NS}: ${obcJson}" "${elapsed}"
        return 1
    fi

    # Helper exit codes are branched on: 1 is the expected "no matching
    # claim", anything else is a broken helper and must not read as absence.
    # The claim has to belong to the discovered QuayRegistry: another
    # registry's claim in the same namespace would otherwise be waited on and
    # reported as this registry's ODF integration.
    typeset quayObc=''
    typeset -i obcPickRc=0
    quayObc=$(printf '%s' "${obcJson}" | \
        python3 -c "
import sys, json, os
registry = os.environ.get('QUAY_REGISTRY', '')
data = json.load(sys.stdin)
owned = []
hinted = []
for item in data.get('items', []):
    meta = item.get('metadata') or {}
    name = meta.get('name') or ''
    if not name:
        continue
    refs = [r for r in (meta.get('ownerReferences') or [])
            if r.get('kind') == 'QuayRegistry']
    bound = ((item.get('status') or {}).get('phase') == 'Bound')
    if any(r.get('name') == registry for r in refs if registry):
        owned.append((0 if bound else 1, name))
    elif registry and name.startswith(registry + '-'):
        hinted.append((0 if bound else 1, name))
pick = sorted(owned) or sorted(hinted)
if pick:
    print(pick[0][1])
    sys.exit(0)
sys.exit(1)
" 2>&1) || obcPickRc=$?

    if (( obcPickRc != 0 && obcPickRc != 1 )); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Could not select a Quay ObjectBucketClaim in namespace ${QUAY_NS} (helper exited ${obcPickRc}: ${quayObc})" "${elapsed}"
        return 1
    fi
    if [[ -z "${quayObc}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "No ObjectBucketClaim found in Quay namespace ${QUAY_NS}" "${elapsed}"
        return 1
    fi

    if ! oc wait "objectbucketclaim/${quayObc}" -n "${QUAY_NS}" \
        --for=jsonpath='{.status.phase}'=Bound --timeout=10m; then
        typeset obcPhase=''
        obcPhase=$(oc get objectbucketclaim "${quayObc}" -n "${QUAY_NS}" \
            -o jsonpath='{.status.phase}' 2>&1) || obcPhase="unknown"
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "ObjectBucketClaim ${quayObc} in namespace ${QUAY_NS} did not reach phase Bound within 10 minutes (observed phase: ${obcPhase:-not set})" "${elapsed}"
        return 1
    fi

    typeset obJson=''
    if ! obJson=$(oc get objectbucket -o json 2>&1); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to list ObjectBuckets: ${obJson}" "${elapsed}"
        return 1
    fi

    typeset obName=''
    typeset -i obPickRc=0
    obName=$(printf '%s' "${obJson}" | \
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
" "${quayObc}" "${QUAY_NS}" 2>&1) || obPickRc=$?

    if (( obPickRc != 0 && obPickRc != 1 )); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Could not resolve the ObjectBucket for Quay OBC ${quayObc} (helper exited ${obPickRc}: ${obName})" "${elapsed}"
        return 1
    fi
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

      # The registration credentials reach the helper through its environment
      # and the payload reaches curl on stdin, so the values appear in neither
      # the helper's argv nor the curl command line.
      typeset regPayload=''
      regPayload=$(QUAY_REG_USER="${regUser}" QUAY_REG_PASSWORD="${regPass}" python3 -c "
import json, os
payload = {
    'name': 'interop-quay-smoke',
    'type': 'docker',
    'categories': ['REGISTRY'],
    'docker': {
        'endpoint': os.environ['QUAY_HOST'],
        'username': os.environ['QUAY_REG_USER'],
        'password': os.environ['QUAY_REG_PASSWORD'],
        'insecure': True
    },
    'skipTestIntegration': True
}
print(json.dumps(payload))
")

      typeset regCode=""
      regCode=$(printf '%s' "${regPayload}" | curl -s "${acsTlsOpts[@]}" -o /dev/null -w '%{http_code}' \
          --connect-timeout 15 --max-time 60 \
          -X POST "https://${acsHost}/v1/imageintegrations" \
          --config <(printf 'user = "admin:%s"\n' "$(cat "${acsPassFile}")") \
          -H "Content-Type: application/json" \
          -d @- 2>/dev/null) || regCode="000"
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
    typeset testName="${testNameAcs}"
    typeset -i start=0 elapsed=0
    start=$(date +%s)

    typeset acsHost=''
    # Only an explicit not-found may record the ACS test as skipped: a route
    # read that fails on a timeout or an authorization error leaves the
    # deployment state unknown, and treating it as absent would let the step
    # pass without scanning an installed ACS.
    typeset -i routeRc=0
    acsHost="$(oc get route -n stackrox central -o jsonpath='{.spec.host}' --ignore-not-found 2>/dev/null)" || routeRc=$?
    if (( routeRc != 0 )); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Could not read the Central route (rc=${routeRc}); the ACS deployment state is unknown, so the scan cannot be classified as skipped" "${elapsed}"
        return 1
    fi
    if [[ -z "${acsHost}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "skipped" "ACS not deployed (Central route not found)" "${elapsed}"
        return 0
    fi

    # The ACS admin password is required once Central is deployed: an
    # unreadable or empty credential is a broken deployment, not an absent one,
    # and must not turn the ACS test into a successful skip.
    typeset -i passRc=0
    ( set +x
      oc get secret -n stackrox central-htpasswd -o jsonpath='{.data.password}' | base64 -d >"${acsPassFile}"
    ) || passRc=$?
    if (( passRc != 0 )) || [[ ! -s "${acsPassFile}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        rm -f "${acsPassFile}"
        RecordResult "${testName}" "failed" "ACS Central is deployed but its admin credential (secret stackrox/central-htpasswd) could not be read (rc=${passRc}); the scan cannot run" "${elapsed}"
        return 1
    fi

    typeset pushTarget="${QUAY_HOST}/interop-smoke-test/ubi-smoke:${imageTag}"

    # TLS verification for the ACS Central API.  The admin credential, and the
    # Quay credential carried in the registration body, are only ever sent
    # over a connection whose certificate is verified: resolve a CA that
    # checks the Central route before the first such request, trying Central's
    # own serving CA (the central route terminates TLS in the pod, so the
    # client sees Central's certificate rather than a router certificate), the
    # ingress router CA, and the service CA bundle mounted in the pod (pattern
    # from interop-opp-must-gather-acs).  There is deliberately no -k
    # fallback: an unverifiable route is recorded failed and no credential is
    # sent.
    # Declared here so the helper functions called below (dynamic scoping)
    # share the same options.
    typeset centralCa=''
    centralCa="$(oc get secret central-tls -n stackrox -o jsonpath='{.data.ca\.pem}' 2>/dev/null | base64 -d 2>/dev/null)" || centralCa=''
    typeset -a acsCaCandidates=()
    if [[ -n "${centralCa}" ]]; then
        printf '%s\n' "${centralCa}" > /tmp/acs-central-ca.crt
        acsCaCandidates+=( /tmp/acs-central-ca.crt )
    fi
    typeset ingressCaBundle=''
    ingressCaBundle="$(oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null)" || ingressCaBundle=''
    if [[ -n "${ingressCaBundle}" ]]; then
        printf '%s\n' "${ingressCaBundle}" > /tmp/acs-ingress-ca.crt
        acsCaCandidates+=( /tmp/acs-ingress-ca.crt )
    fi
    typeset saCaBundle='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
    if [[ -f "${saCaBundle}" ]]; then
        acsCaCandidates+=( "${saCaBundle}" )
    fi
    typeset acsCaFile=''
    typeset candidateCa=''
    typeset tlsProbe=''
    if (( ${#acsCaCandidates[@]} > 0 )); then
        for candidateCa in "${acsCaCandidates[@]}"; do
            tlsProbe="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 --cacert "${candidateCa}" "https://${acsHost}/v1/ping")" || tlsProbe='000'
            if [[ -n "${tlsProbe}" && "${tlsProbe}" != '000' ]]; then
                acsCaFile="${candidateCa}"
                break
            fi
        done
    fi
    if [[ -z "${acsCaFile}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Could not verify the ACS Central route certificate for ${acsHost} with Central's serving CA (secret stackrox/central-tls), the ingress router CA or the service CA bundle; refusing to send the admin credential over unverified TLS" "${elapsed}"
        rm -f "${acsPassFile}" /tmp/acs-ingress-ca.crt /tmp/acs-central-ca.crt
        return 1
    fi
    typeset -a acsTlsOpts=( --cacert "${acsCaFile}" )

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

    typeset -i attempts=0 maxAttempts=40 retryInterval=15
    typeset -i waitMinutes=$(( maxAttempts * retryInterval / 60 ))
    typeset -i answeredAttempts=0
    typeset lastQueryError=''

    while (( attempts < maxAttempts )); do
        typeset scanResult='' scanErrFile='/tmp/acs-query.err'
        typeset -i scanRc=0
        scanResult="$(
            set +x
            curl -fsSL "${acsTlsOpts[@]}" --connect-timeout 15 --max-time 30 \
                --config <(printf 'user = "admin:%s"\n' "$(cat "${acsPassFile}")") \
                "https://${acsHost}/v1/images?query=Image:${pushTarget}" 2>"${scanErrFile}"
        )" || scanRc=$?

        # The helper answers 0 (image present), 1 (image absent) or anything
        # else (helper or parse failure).  A failure must not read as "ACS did
        # not detect the image", so the three outcomes are tracked apart.
        # parseRc starts at 2: a helper that neither succeeds nor reports a
        # status is a failure, not an answered query.
        typeset -i parseRc=2
        if (( scanRc == 0 )); then
            parseRc=0
            printf '%s' "${scanResult}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
sys.exit(0 if data.get('images') else 1)
" || parseRc=$?
        fi

        if (( scanRc == 0 && parseRc == 0 )); then
            elapsed=$(( $(date +%s) - start ))
            RecordResult "${testName}" "passed" "" "${elapsed}"
            return 0
        fi

        if (( scanRc == 0 && parseRc == 1 )); then
            answeredAttempts=$(( answeredAttempts + 1 ))
        else
            lastQueryError=$(cat "${scanErrFile}" 2>/dev/null) || lastQueryError=''
            if [[ -z "${lastQueryError}" ]]; then
                if (( scanRc != 0 )); then
                    lastQueryError="curl exited ${scanRc} without error output"
                else
                    lastQueryError="helper exited ${parseRc} without error output"
                fi
            fi
            if (( attempts % 8 == 0 )); then
                echo "WARNING: ACS image query failed on attempt ${attempts} of ${maxAttempts}: ${lastQueryError}" >&2
            fi
        fi

        if (( attempts % 4 == 3 )); then
            RequestAcsScan "${acsHost}" "${pushTarget}" || true
        fi

        attempts=$((attempts + 1))
        sleep "${retryInterval}"
    done

    elapsed=$(( $(date +%s) - start ))
    if (( answeredAttempts == 0 )); then
        RecordResult "${testName}" "failed" "ACS never answered the image query within ${waitMinutes} minutes (last error: ${lastQueryError:-unknown}); this is a query failure, not a missing image" "${elapsed}"
    else
        RecordResult "${testName}" "failed" "ACS did not detect pushed image within ${waitMinutes} minutes (${answeredAttempts} answered queries)" "${elapsed}"
    fi
    return 1
}

################################################################################
# Main execution
################################################################################

function Main () {
    # python3 carries every JSON filter in this step: without it the
    # discovery and polling helpers cannot tell "absent" from "broken", so
    # fail hard here instead of degrading into a false green.
    if ! command -v python3 >/dev/null 2>&1; then
        echo "FATAL: python3 is required for the Quay, ODF and ACS checks but is not installed in this image" >&2
        for t in "${allTests[@]}"; do
            RecordResult "${t}" "failed" "python3 not available in the step image"
        done
        exit 1
    fi

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
    if ! ResolveQuayTlsTrust; then
        for t in "${allTests[@]}"; do
            RecordResult "${t}" "failed" "Quay route TLS could not be verified; no credential was sent"
        done
        exit 1
    fi
    if ! GetQuayAuth; then
        for t in "${allTests[@]}"; do
            RecordResult "${t}" "failed" "Quay credential retrieval failed"
        done
        exit 1
    fi
    if ! PreflightCheck; then
        echo "FATAL: Quay not reachable; skipping all tests" >&2
        RecordResult "${testNamePushPull}" "failed" "Quay registry discovery endpoint not reachable"
        RecordResult "${testNameOdf}" "skipped" "Skipped: Quay preflight (discovery endpoint) failed"
        RecordResult "${testNameAcs}" "skipped" "Skipped: Quay preflight (discovery endpoint) failed"
        exit 1
    fi
    # The organization request is what makes the push target writable, so a
    # recorded organization failure is why the push lane is skipped: running
    # the push would only overwrite that reason with a symptom of it.
    typeset -i orgRc=0
    CreateTestOrg || orgRc=$?

    typeset -i status=0 pushPassed=0
    if (( orgRc == 0 )); then
        RunPushPull && pushPassed=1 || status=1
    else
        status=1
    fi
    RunOdfStorageCheck || status=1
    if (( pushPassed )); then
        RunAcsScan || status=1
    else
        RecordResult "${testNameAcs}" "skipped" "Skipped: push-pull test failed; no image available to scan"
    fi

    exit "${status}"
}

Main "$@"

