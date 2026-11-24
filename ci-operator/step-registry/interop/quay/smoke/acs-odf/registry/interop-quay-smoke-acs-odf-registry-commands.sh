#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Restrictive default permissions: the credential files this step writes
# under /tmp are owner-only, whatever the image's default umask was.
umask 077

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}

# shellcheck disable=SC2154
_opp_cleanup() {
  typeset -i _exit_code="${1:-0}"
  set +x
  # Credential hygiene: these files must not survive the step, on the
  # success and the failure path alike.
  rm -f /tmp/quay-auth.json /tmp/quay-cookies.txt "${acsPassFile:-/tmp/acs-admin-password}" /tmp/acs-ingress-ca.crt /tmp/acs-central-ca.crt /tmp/quay-push.digest
  rm -rf /tmp/quay-ca-candidates
  # Scrub credentials before copying
  sed -i -E \
    -e 's/(password|token|secret|key|credential)=[^ ]*/\1=REDACTED/gi' \
    -e 's/Bearer [A-Za-z0-9._~+\/=-]+/Bearer [REDACTED]/g' \
    -e 's/password=[^ &]+/password=[REDACTED]/g' \
    -e 's/token=[^ &]+/token=[REDACTED]/g' \
    -e 's|://[^:@/]*:[^:@/]*@|://[REDACTED]:[REDACTED]@|g' \
    "${_xtrace_log}" || true
  if [[ ${_exit_code} -ne 0 && -n "${ARTIFACT_DIR:-}" ]]; then
    cp "${_xtrace_log}" "${ARTIFACT_DIR}/" || true
    echo ">>> TRACE: xtrace log saved to artifacts (exit code ${_exit_code})" >&2
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
  typeset _genRc=0
  type -t GenerateJunit >/dev/null && GenerateJunit || _genRc=$?
  type -t _propagate_junit >/dev/null && _propagate_junit
  type -t PostProcessJunit >/dev/null && PostProcessJunit
  # Validate the report the routing mode actually consumes, on every exit path.
  typeset _sharedMerged="${SHARED_DIR:-/tmp}/junit--interop-quay-smoke-acs-odf-registry.xml"
  typeset _localMerged="${ARTIFACT_DIR:-/tmp}/junit--interop-quay-smoke-acs-odf-registry.xml"
  typeset _rawJunitToRemove=''
  typeset -i _mergedValid=0
  if [[ -n "${SHARED_DIR:-}" && -s "${_sharedMerged}" ]] \
      && python3 -c "import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])" "${_sharedMerged}" 2>/dev/null; then
      _mergedValid=1
      if [[ -n "${LP_QE__CR__TS_NAME__PFX__QUAY:-}" ]] \
          && ! python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
names = [ts.get('name', '') for ts in root.iter('testsuite')]
sys.exit(0 if names and all(n.startswith(sys.argv[2]) for n in names) else 1)
" "${_sharedMerged}" "${LP_QE__CR__TS_NAME__PFX__QUAY}--" 2>/dev/null; then
          _mergedValid=0
      fi
  fi
  # A merge that did not validate must not sit in the reporter glob.
  if (( _mergedValid == 0 )) && [[ -e "${_sharedMerged}" ]]; then
      rm -f "${_sharedMerged}"
  fi
  if (( _genRc != 0 && exitCode == 0 )); then
      echo "ERROR: JUnit report generation failed for otherwise successful run" >&2
      exit 1
  fi
  if (( exitCode == 0 )); then
      if [[ -n "${LP_QE__CR__TS_NAME__PFX__QUAY:-}" ]]; then
          if (( _mergedValid == 0 )); then
              echo "ERROR: LP_QE__CR__TS_NAME__PFX__QUAY is set but ${_sharedMerged} is missing, invalid, or does not carry the component prefix; the run would report green with no routable JUnit" >&2
              exit 1
          fi
      elif (( _mergedValid == 0 )) \
          && ! python3 -c "import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])" "${junitFile}" 2>/dev/null \
          && ! python3 -c "import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])" "${_localMerged}" 2>/dev/null; then
          echo "ERROR: no valid JUnit report in ${junitFile}, ${_sharedMerged} or ${_localMerged} for successful run" >&2
          exit 1
      fi
  fi
  if (( _mergedValid == 1 )); then
      _rawJunitToRemove="${SHARED_DIR}/$(basename "${junitFile}")"
  fi
  if [[ -n "${_rawJunitToRemove}" ]]; then
      rm -f "${_rawJunitToRemove}"
  fi
  true
}
trap '_opp_trap_handler' EXIT

: "PHASE: initialization"

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

EscapeForCurlUser() {
    sed 's/\\/\\\\/g; s/"/\\"/g'
}

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

    typeset _junitTmp="${junitFile}.tmp"
    cat > "${_junitTmp}" <<EOF
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
            typeset safeFailure="${testFailureMsg[${t}]//]]>/]]]]><![CDATA[>}"
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-quay-smoke-acs-odf-registry\" time=\"${testDuration[${t}]}\"><failure message=\"${escapedMsg}\"><![CDATA[${safeFailure}]]></failure></testcase>" >> "${_junitTmp}"
        elif [[ "${testStatus[${t}]}" == "skipped" ]]; then
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-quay-smoke-acs-odf-registry\" time=\"${testDuration[${t}]}\"><skipped message=\"${escapedMsg}\"/></testcase>" >> "${_junitTmp}"
        else
            echo "    <testcase name=\"${escapedName}\" classname=\"interop-quay-smoke-acs-odf-registry\" time=\"${testDuration[${t}]}\"/>" >> "${_junitTmp}"
        fi
    done

    cat >> "${_junitTmp}" <<'EOF'
  </testsuite>
</testsuites>
EOF
    if python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
if len(root.findall('.//testcase')) != int(sys.argv[2]):
    sys.exit(1)
" "${_junitTmp}" "${total}" 2>/dev/null; then
        if ! mv -f "${_junitTmp}" "${junitFile}"; then
            echo "ERROR: failed to move JUnit report from ${_junitTmp} to ${junitFile}" >&2
            rm -f "${_junitTmp}"
            if (( failures == 0 )); then
                echo "ERROR: required JUnit artifact not produced for successful run" >&2
            fi
            return 1
        fi
        cat "${junitFile}"
    else
        echo "ERROR: JUnit report at ${_junitTmp} is invalid or incomplete" >&2
        rm -f "${_junitTmp}"
        if (( failures == 0 )); then
            echo "ERROR: required JUnit artifact not produced for successful run" >&2
            return 1
        fi
    fi
}

# shellcheck disable=SC2317
_propagate_junit () {
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    cp "${junitFile}" "${SHARED_DIR}/" 2>/dev/null || true
    find "${ARTIFACT_DIR:-}" -name '*.xml' -exec cp {} "${SHARED_DIR}/" \; 2>/dev/null || true
}

# Load ExitTrap library for JUnit XML post-processing at script level
# (must be loaded before trap can fire to avoid secondary errors).
typeset _exitTrapHelper=""
typeset -i _exitTrapDlRc=0
if ! _exitTrapHelper="$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/2420b542141e9009f29ce02551244ebc43ed7060/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
)"; then
    _exitTrapDlRc=$?
    printf '%s\n' "WARNING: failed to download ExitTrap helper (rc=${_exitTrapDlRc})" >&2
elif [[ -z "${_exitTrapHelper}" ]]; then
    printf '%s\n' "WARNING: ExitTrap helper download returned empty body" >&2
else
    # Pin transitive dependency: the helper at 2420b542 fetches EnsureReqs.sh from refs/heads/main (moving branch)
    # Replace with commit-qualified raw URL so the pin fully controls the supply chain
    _exitTrapHelper="${_exitTrapHelper//refs\/heads\/main/2420b542141e9009f29ce02551244ebc43ed7060}"
    eval "${_exitTrapHelper}"
fi

# Post-process the JUnit XML for Component Readiness routing.  Guarded on
# purpose: this runs from the EXIT trap, and an unloaded helper (download
# failure) or a post-processing failure must not overwrite the script's
# exit status (the unguarded call fails the trap with 127 and turns a
# passing run into a failure).  The merged file name is passed explicitly:
# the library default (jUnit.xml) is not picked up by the prow JUnit viewer
# (lowercase junit prefix required) and collides with other steps in
# shared storage.
PostProcessJunit () {
    typeset -i _junitPreSize=0
    [[ -f "${junitFile}" ]] && _junitPreSize=$(wc -c < "${junitFile}" 2>/dev/null || echo 0)
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        ExitTrap--PostProcessPrep junit--interop-quay-smoke-acs-odf-registry.xml
        typeset -i _junitRc=$?
        if (( _junitRc != 0 )); then
            echo "WARNING: junit post-processing failed (rc=${_junitRc})" >&2
            if (( _junitPreSize > 0 )) && [[ ! -s "${junitFile}" ]]; then
                echo "WARNING: post-processing removed raw report, size was ${_junitPreSize}" >&2
            fi
        fi
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
        : "INFO: QuayRegistry CRD absent; Quay is not deployed"
        return 1
    fi

    typeset registryJson="" discoverErr=""
    if ! registryJson="$(oc get quayregistry --all-namespaces -o json 2>"${ARTIFACT_DIR:-/tmp}/quayregistry-err.log")"; then
        discoverErr="$(cat "${ARTIFACT_DIR:-/tmp}/quayregistry-err.log" 2>/dev/null || echo "oc get failed")"
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
        : "INFO: No QuayRegistry found; Quay is not deployed"
        return 1
    fi

    QUAY_NS="$(printf '%s' "${registryJson}" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][0]['metadata']['namespace'])")"
    QUAY_REGISTRY="$(printf '%s' "${registryJson}" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][0]['metadata']['name'])")"
    QUAY_UID="$(printf '%s' "${registryJson}" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][0]['metadata']['uid'])")"
    QUAY_CONFIG_BUNDLE="$(printf '%s' "${registryJson}" | python3 -c "import sys,json; print((json.load(sys.stdin)['items'][0].get('spec') or {}).get('configBundleSecret') or '')")"

    QUAY_HOST="$(oc get quayregistry -n "${QUAY_NS}" "${QUAY_REGISTRY}" -o jsonpath='{.status.registryEndpoint}')"
    QUAY_HOST="${QUAY_HOST#https://}"
    if [[ -z "${QUAY_HOST}" ]]; then
        echo "ERROR: QuayRegistry ${QUAY_REGISTRY} exists but its registryEndpoint is empty (route not ready)" >&2
        # rc 2: Quay is deployed but not usable: distinct from rc 1 (Quay
        # not deployed), so the caller fails instead of reporting a skip.
        return 2
    fi
    export QUAY_NS QUAY_REGISTRY QUAY_HOST QUAY_UID QUAY_CONFIG_BUNDLE
    true
}

# TLS verification for the Quay route: the route certificate is issued by
# the Quay operator's own CA and is not trusted by step pods, so the route
# certificate is resolved from cluster state (route object, operator-owned
# secrets, ingress CA, image trust store) and used as an explicit trust
# anchor for every credential-bearing request; see ResolveQuayTlsTrust.  The
# pushed image is still verified by pulling it back.
typeset QUAY_USER='' QUAY_PASSWORD='' QUAY_TOKEN=''
typeset QUAY_CONFIG_BUNDLE=''
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
            echo "INFO: Quay credentials obtained from quayadmin secret" >&2
        fi
    fi

    if [[ "${authOk}" == false ]]; then
        if oc get secret quaydevel -n "${QUAY_NS}" -o name 1>/dev/null; then
            QUAY_PASSWORD="$(oc get secret quaydevel -n "${QUAY_NS}" -o jsonpath='{.data.password}' | base64 -d)" || QUAY_PASSWORD=""
            QUAY_USER="quaydevel"
            if [[ -n "${QUAY_PASSWORD}" ]]; then
                authOk=true
                echo "INFO: Quay credentials obtained from quaydevel secret" >&2
            fi
        fi
    fi

    if [[ "${authOk}" == false ]]; then
        typeset initPassword=''
        # Durable restricted storage: SHARED_DIR survives a new CI pod while /tmp does not;
        # fallback to /tmp only when SHARED_DIR is absent (e.g. local runs). Directory is
        # 0700 and file is 0600 (umask 077 plus explicit chmod).
        typeset quayInitPassFile="${SHARED_DIR:-/tmp}/quay-init-password"
        if [[ -n "${SHARED_DIR:-}" ]]; then
            mkdir -p "${SHARED_DIR}" 2>/dev/null || true
            chmod 0700 "${SHARED_DIR}" 2>/dev/null || true
        fi
        if [[ -s "${quayInitPassFile}" ]]; then
            initPassword="$(cat "${quayInitPassFile}")"
            chmod 600 "${quayInitPassFile}" || true
            echo "INFO: reusing persisted Quay init password from prior attempt" >&2
        else
            initPassword="$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))")"
            printf '%s' "${initPassword}" > "${quayInitPassFile}"
            chmod 600 "${quayInitPassFile}"
        fi
        typeset initResult=''
        typeset initBody=''
        typeset initHttp=''
        # The payload is built by json.dumps and piped in via stdin, so the
        # generated password is safely escaped and never part of any argv.
        # no -L: the generated password is in the POST body, so a redirect on
        # this endpoint must not be followed.  -f still fails the call on an
        # HTTP error, and the retry loop reads a redirect body as a failure.
        # PRRT_kwDOBHvUUM65TpNF: single init request with bounded retry
        typeset -i _initTry=0
        typeset _alreadyExists=false
        for _initTry in 1 2 3; do
            typeset initRaw=''
            initRaw="$(printf '%s' "${initPassword}" | python3 -c "
import json, sys
print(json.dumps({'username': 'quayadmin', 'password': sys.stdin.read().strip(), 'email': 'quayadmin@example.com', 'access_token': True}))
" | curl -sS -w '\n%{http_code}' "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 60 -X POST "https://${QUAY_HOST}/api/v1/user/initialize" \
                    -H "Content-Type: application/json" \
                    -d @- 2>&1)" || true
            initHttp="$(printf '%s' "${initRaw}" | tail -n1)"
            initBody="$(printf '%s' "${initRaw}" | sed '$d')"
            if [[ "${initHttp}" =~ ^2[0-9]{2}$ && -n "${initBody}" ]]; then
                initResult="${initBody}"
                break
            fi
            if printf '%s' "${initBody}" | grep -qi "already exists\|user exists\|non-empty database\|Cannot initialize user"; then
                _alreadyExists=true
                initResult="${initBody}"
                break
            fi
            if (( _initTry < 3 )); then
                sleep $(( _initTry * 2 ))
            fi
        done
        if [[ "${_alreadyExists}" == true ]]; then
            echo "INFO: user already exists, attempting login with persisted password" >&2
            typeset _loginCsrf=''
            _loginCsrf="$(curl -fsSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 "https://${QUAY_HOST}/csrf_token" -c /tmp/quay-cookies.txt 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))")" || _loginCsrf=""
            if [[ -n "${_loginCsrf}" ]]; then
                typeset _loginResult=''
                _loginResult="$(QUAY_USER_FALLBACK="quayadmin" QUAY_PASS_FILE="${quayInitPassFile}" python3 -c "
import json, os
print(json.dumps({'username': os.environ['QUAY_USER_FALLBACK'], 'password': open(os.environ['QUAY_PASS_FILE']).read().strip()}))
" | curl -sS "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 60 -X POST "https://${QUAY_HOST}/api/v1/signin" \
                    -H "Content-Type: application/json" \
                    -H "X-CSRF-Token: ${_loginCsrf}" \
                    -b /tmp/quay-cookies.txt -c /tmp/quay-cookies.txt \
                    -d @- 2>&1)" || _loginResult=""
                typeset _loginOk=''
                _loginOk="$(printf '%s' "${_loginResult}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)" || _loginOk=""
                if [[ "${_loginOk}" == "True" ]]; then
                    QUAY_USER="quayadmin"
                    QUAY_PASSWORD="${initPassword}"
                    authOk=true
                    echo "INFO: recovered Quay admin via login with persisted password after user exists" >&2
                fi
            fi
            if [[ "${authOk}" == false ]]; then
                echo "WARNING: login with persisted password failed; init response: ${initBody:0:200}" >&2
            fi
        else
            QUAY_TOKEN="$(printf '%s' "${initResult}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)" || QUAY_TOKEN=""
            if [[ -n "${QUAY_TOKEN}" ]]; then
                QUAY_USER="quayadmin"
                QUAY_PASSWORD="${initPassword}"
                authOk=true
                echo "INFO: Quay admin user initialized via /api/v1/user/initialize" >&2
            fi
        fi
    fi

    if [[ "${authOk}" == true ]]; then
        rm -f "${quayInitPassFile}" || true
    else
        # Retain the credential when the outcome is uncertain (lost response): /tmp does
        # not survive a new CI pod and the previous code deleted the file when authOk
        # stayed false after timeouts. Only a definitive failure (init returned an error
        # body that is not a timeout/transport loss) removes the persisted password.
        typeset _quayOutcomeUncertain=false
        if [[ "${_alreadyExists:-false}" == false ]]; then
            # No definitive server response: empty body/http or transport error means the
            # account may have been created but the response was lost.
            if [[ -z "${initBody:-}" && -z "${initHttp:-}" ]] || [[ "${initHttp:-}" == "000" ]] || [[ "${initHttp:-}" == "" ]]; then
                _quayOutcomeUncertain=true
            fi
        fi
        if [[ "${_quayOutcomeUncertain}" == true ]]; then
            echo "INFO: retaining persisted Quay init password for recovery on next invocation (outcome uncertain)" >&2
        else
            if [[ -f "${quayInitPassFile}" ]]; then
                echo "INFO: removing persisted Quay init password after definitive auth failure; a new invocation will generate a fresh password" >&2
                rm -f "${quayInitPassFile}" || true
            fi
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

# Self-test for credential recovery across two invocations: the first invocation
# loses the initialize response (transport timeout, empty http), the persisted
# password must survive in restricted durable storage and be reused on the
# second invocation to recover via login; validates that /tmp is not used and
# that the file is retained when the outcome is uncertain.
QuayInitRecoverySelfTest() {
    typeset _testTmp="${SHARED_DIR:-/tmp}/quay-selftest-$$"
    mkdir -p "${_testTmp}" 2>/dev/null || true
    chmod 0700 "${_testTmp}" 2>/dev/null || true
    typeset _origShared="${SHARED_DIR:-}"
    export SHARED_DIR="${_testTmp}"
    typeset _origQuayHost="${QUAY_HOST:-}"
    export QUAY_HOST="quay-test.example.com"
    typeset _origNs="${QUAY_NS:-}"
    export QUAY_NS="test-ns"
    # Mock oc to report no existing secrets (so GetQuayAuth enters init path)
    oc() { return 1; }
    export -f oc
    # First invocation: curl for initialize returns empty (lost response)
    curl() {
        if [[ "$*" == *"/api/v1/user/initialize"* ]]; then
            printf ''
            return 0
        fi
        return 1
    }
    export -f curl
    typeset _firstPassFile="${SHARED_DIR}/quay-init-password"
    rm -f "${_firstPassFile}" || true
    # Stub QUAY_HOST and quayTlsOpts for the test
    quayTlsOpts=()
    # Disable tracing for the test
    set +x
    GetQuayAuth || true
    typeset _firstExists=false
    [[ -s "${_firstPassFile}" ]] && _firstExists=true
    typeset _firstPw=""
    [[ "${_firstExists}" == true ]] && _firstPw="$(cat "${_firstPassFile}")"
    # Second invocation: simulate Quay now reports user exists, login succeeds with same password
    curl() {
        if [[ "$*" == *"/api/v1/user/initialize"* ]]; then
            printf '{"message":"user already exists"}\n409'
            return 0
        fi
        if [[ "$*" == *"/csrf_token"* ]]; then
            printf '{"csrf_token":"test-csrf"}'
            return 0
        fi
        if [[ "$*" == *"/api/v1/signin"* ]]; then
            printf '{"success": true}'
            return 0
        fi
        return 1
    }
    export -f curl
    GetQuayAuth || true
    typeset _secondPw="${QUAY_PASSWORD:-}"
    # Restore
    SHARED_DIR="${_origShared}"
    QUAY_HOST="${_origQuayHost}"
    QUAY_NS="${_origNs}"
    unset -f oc curl
    rm -rf "${_testTmp}" || true
    if [[ "${_firstExists}" != true ]]; then
        echo "SELF-TEST FAIL: first invocation did not retain password file in durable storage" >&2
        return 1
    fi
    if [[ "${_firstPw}" != "${_secondPw}" ]]; then
        echo "SELF-TEST FAIL: second invocation did not reuse persisted password (first:${_firstPw:0:4}.. second:${_secondPw:0:4}..)" >&2
        return 1
    fi
    echo "SELF-TEST PASS: credential recovered across two invocations via durable storage" >&2
    return 0
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
    routeCert="$(oc get routes -n "${QUAY_NS}" -o json | \
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
    oc get secrets -n "${QUAY_NS}" -o json | \
        QUAY_OWNER="${QUAY_REGISTRY}" QUAY_OWNER_UID="${QUAY_UID:-}" QUAY_BUNDLE_SECRET="${QUAY_CONFIG_BUNDLE:-}" CA_DIR="${quayCaDir}" python3 -c "
import base64, json, os, sys

try:
    items = json.load(sys.stdin).get('items', [])
except Exception:
    items = []

owner = os.environ['QUAY_OWNER']
owner_uid = os.environ.get('QUAY_OWNER_UID') or ''
ca_dir = os.environ['CA_DIR']
counts = {'20-owned': 0, '25-ssl': 0}


def write(prefix, payload):
    counts[prefix] += 1
    path = os.path.join(ca_dir, '%s-%02d.pem' % (prefix, counts[prefix]))
    with open(path, 'wb') as fh:
        fh.write(payload)


bundle = os.environ.get('QUAY_BUNDLE_SECRET') or ''

def is_owned(refs):
    for r in refs:
        if owner_uid and r.get('uid') == owner_uid:
            return True
    return False

# Primary: secrets owned by selected QuayRegistry (uid match) or the config bundle secret
for s in items:
    meta = s.get('metadata') or {}
    refs = meta.get('ownerReferences') or []
    owned = is_owned(refs)
    data = s.get('data') or {}
    from_bundle = bool(bundle) and meta.get('name') == bundle
    if not owned and not from_bundle:
        continue
    if owned:
        for key in ('ca.crt', 'tls.crt'):
            if data.get(key):
                write('20-owned', base64.b64decode(data[key]))
        if data.get('ssl.cert'):
            write('25-ssl', base64.b64decode(data['ssl.cert']))
    elif from_bundle:
        if data.get('ssl.cert'):
            write('25-ssl', base64.b64decode(data['ssl.cert']))
        if data.get('ca.crt'):
            write('20-owned', base64.b64decode(data['ca.crt']))

# Fallback: label-matched unowned secrets only when no owned candidate exists
if counts['20-owned'] == 0 and counts['25-ssl'] == 0:
    fallback_used = False
    for s in items:
        meta = s.get('metadata') or {}
        data = s.get('data') or {}
        if data.get('ssl.cert') and (meta.get('labels') or {}).get('app') == 'quay':
            write('25-ssl', base64.b64decode(data['ssl.cert']))
            fallback_used = True
    if fallback_used:
        print('WARNING: no owned Quay TLS secret found for %s (uid %s); falling back to label app=quay secrets' % (owner, owner_uid), file=sys.stderr)
" || { _rc=$?; echo "WARNING: Quay TLS trust candidate extraction failed (python rc=${_rc})" >&2; }

    # The ingress CA signs route certificates that no operator issued.
    typeset ingressCa=''
    ingressCa="$(oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}')" || ingressCa=''
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
    : "INFO: Quay route TLS verified against ${quayCaFile}"
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
            python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))")" || csrf=""

        if [[ -n "${csrf}" ]]; then
            typeset signinResult=''
            # The payload is built inside the helper from the environment
            # (the variables are exported above), and piped in via stdin, so
            # the password appears in neither the helper's argv nor the curl
            # command line.
            # no -L: the password and the X-CSRF-Token header are on this POST,
            # so a redirect must not be followed; -f fails the call on an HTTP
            # error, and a redirect body is not a signin success.
            signinResult="$(python3 -c "
import json, os
print(json.dumps({'username': os.environ['QUAY_USER'], 'password': os.environ['QUAY_PASSWORD']}))
" | curl -fsS "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 -X POST "https://${QUAY_HOST}/api/v1/signin" \
                -H "Content-Type: application/json" \
                -H "X-CSRF-Token: ${csrf}" \
                -b "${cookieFile}" -c "${cookieFile}" \
                -d @-)" || signinResult=""
            # /api/v1/signin answers {"success": true} and sets the session
            # cookie; it does not return a token.  Read the success flag too,
            # and keep the cookie jar for the organization request.
            QUAY_TOKEN="$(printf '%s' "${signinResult}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")" || QUAY_TOKEN=""
            export QUAY_TOKEN
            typeset signinOk=''
            signinOk="$(printf '%s' "${signinResult}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))")" || signinOk=""
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
                    python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))")" || csrf=""
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
    # of a rejected request names the rejection, so this request fails with
    # --fail-with-body (never -f, which drops it) and -w keeps the status.
    typeset orgRaw=''
    typeset orgResponse=''
    typeset orgHttp='000'
    typeset -i orgRc=0
    if [[ -z "${QUAY_TOKEN}" && -f "${cookieFile}" && -n "${csrf}" ]]; then
        # Password-only signin produced a session, not a token: send the
        # session cookie and the CSRF token refreshed for that session,
        # otherwise this request goes out with an empty bearer header and the
        # push below has no organization.
        # no -L: the CSRF token must not follow a redirect, and %{http_code} must report the initial response
        orgRaw="$(curl -sS --fail-with-body "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 60 -X POST \
            -w '\n%{http_code}' \
            "https://${QUAY_HOST}/api/v1/organization/" \
            -b "${cookieFile}" \
            -H "X-CSRF-Token: ${csrf}" \
            "${orgPayloadOpts[@]}")" || orgRc=$?
    else
        # The bearer token is handed to curl through a process-substitution
        # config, so it never appears in the curl argv.
        # no -L: the CSRF token must not follow a redirect, and %{http_code} must report the initial response
        orgRaw="$(curl -sS --fail-with-body "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 60 -X POST \
            -w '\n%{http_code}' \
            "https://${QUAY_HOST}/api/v1/organization/" \
            --config <(printf 'header = "Authorization: Bearer %s"\n' "${QUAY_TOKEN}") \
            "${orgPayloadOpts[@]}")" || orgRc=$?
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
        python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))")" || orgSuccess=''
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
                "https://${QUAY_HOST}/api/v1/organization/interop-smoke-test")" || orgPresentHttp=''
        else
            orgPresentHttp="$(curl -sSL "${quayTlsOpts[@]}" --connect-timeout 15 --max-time 30 -o /dev/null \
                -w '%{http_code}' \
                --config <(printf 'header = "Authorization: Bearer %s"\n' "${QUAY_TOKEN}") \
                "https://${QUAY_HOST}/api/v1/organization/interop-smoke-test")" || orgPresentHttp=''
        fi
        if [[ "${orgPresentHttp}" != "200" ]]; then
            typeset orgError=''
            orgError="$(printf '%s' "${orgResponse}" | \
                python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error') or d.get('error_message') or d.get('message') or '')")" || orgError=''
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
        # PRRT_kwDOBHvUUM65LZ3W: first list empty should still bound wait for claim
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
      rm -f "${authFile}"
      printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${QUAY_HOST}" "${registryAuth}" >"${authFile}"
      chmod 600 "${authFile}"
    true )

    typeset digestFile='/tmp/quay-push.digest'
    rm -f "${digestFile}"
    if ! SSL_CERT_FILE="${quayCaFile}" skopeo copy --dest-tls-verify=true \
        --dest-authfile="${authFile}" \
        --digestfile "${digestFile}" \
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
    # PRRT_kwDOBHvUUM65TpNJ: pull by digest not tag to avoid TOCTOU; digest from push digestfile preferred
    typeset pullDir='/tmp/quay-pull-verify'
    rm -rf "${pullDir}"
    typeset imageDigest=""
    if [[ -s "${digestFile}" ]]; then
        imageDigest="$(cat "${digestFile}")"
        imageDigest="${imageDigest%% *}"
        imageDigest="$(printf '%s' "${imageDigest}" | tr -d '[:space:]')"
    fi
    # Fallback to inspect only when push did not record a digest; residual race: tag may have been replaced between push and inspect
    typeset inspectJson=''
    typeset -i inspectRc=0
    if [[ -z "${imageDigest}" ]]; then
        inspectJson=$(SSL_CERT_FILE="${quayCaFile}" skopeo inspect --authfile="${authFile}" "docker://${pushTarget}" 2>/dev/null) || inspectRc=$?
        if (( inspectRc == 0 )); then
            imageDigest=$(printf '%s' "${inspectJson}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Digest',''))") || imageDigest=""
        fi
    fi
    if [[ -z "${imageDigest}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Could not determine image digest after push (skopeo inspect exit ${inspectRc}, digest '${imageDigest:-empty}')" "${elapsed}"
        return 1
    fi
    # Strip only the final tag segment (after last slash) when constructing repo@digest; preserves registry port
    typeset repoPart="${pushTarget}"
    if [[ "${pushTarget##*/}" == *":"* ]]; then
        repoPart="${pushTarget%:*}"
    fi
    typeset pushTargetDigest="${repoPart}@${imageDigest}"
    # Publish digest-anchored pullspec for ACS scan and polling
    typeset -g quayImageDigest="${imageDigest}"
    typeset -g quayPushTargetDigest="${pushTargetDigest}"
    if ! SSL_CERT_FILE="${quayCaFile}" skopeo copy --src-tls-verify=true \
        --src-authfile="${authFile}" \
        "docker://${pushTargetDigest}" \
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
    # PRRT_kwDOBHvUUM65LZ3O: claim owner check before name match to avoid hijacking
    if ! obcJson=$(oc get objectbucketclaim -n "${QUAY_NS}" -o json 2>"${ARTIFACT_DIR:-/tmp}/obc-err.log"); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to list ObjectBucketClaims in namespace ${QUAY_NS}: $(cat "${ARTIFACT_DIR:-/tmp}/obc-err.log" 2>/dev/null || echo "oc get failed")" "${elapsed}"
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
import sys, json, os, traceback
try:
    registry = os.environ.get('QUAY_REGISTRY', '')
    uid = os.environ.get('QUAY_UID', '')

    def owned_by_this(r):
        # Name alone matches a deleted and recreated registry; the uid pins the
        # owner when both sides carry one.
        if not registry or (r.get('name') or '') != registry:
            return False
        ref_uid = r.get('uid') or ''
        return not (uid and ref_uid) or ref_uid == uid

    data = json.load(sys.stdin)
    owned = []
    hinted = []
    for item in data.get('items', []):
        meta = item.get('metadata') or {}
        name = meta.get('name') or ''
        if not name:
            continue
        refs = [r for r in (meta.get('ownerReferences') or []) if r.get('kind') == 'QuayRegistry']
        bound = ((item.get('status') or {}).get('phase') == 'Bound')
        if any(owned_by_this(r) for r in refs):
            owned.append((0 if bound else 1, name))
        elif registry and (name == registry or name.startswith(registry + '-')):
            if not any(r.get('kind') == 'QuayRegistry' and not owned_by_this(r) for r in (meta.get('ownerReferences') or [])):
                hinted.append((0 if bound else 1, name))
    pick = sorted(owned) or sorted(hinted)
    if pick:
        print(pick[0][1])
        sys.exit(0)
    sys.exit(1)
except Exception:
    traceback.print_exc()
    sys.exit(2)
") || obcPickRc=$?

    if (( obcPickRc != 0 && obcPickRc != 1 )); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Could not select a Quay ObjectBucketClaim in namespace ${QUAY_NS} (helper exited ${obcPickRc}: ${quayObc})" "${elapsed}"
        return 1
    fi
    if [[ -z "${quayObc}" ]]; then
        # NooBaa may still be provisioning the claim; wait for it to appear before failing
        typeset -i _claimDeadline=$(( $(date +%s) + 300 ))
        typeset -i _obcListErr=0
        typeset -i _obcPickErr=0
        typeset _obcListMsg=""
        while true; do
            typeset -i _pickRc=0
            quayObc=$(printf '%s' "${obcJson}" | python3 -c "
import sys, json, os, traceback
try:
    registry = os.environ.get('QUAY_REGISTRY', '')
    uid = os.environ.get('QUAY_UID', '')

    def owned_by_this(r):
        # Name alone matches a deleted and recreated registry; the uid pins the
        # owner when both sides carry one.
        if not registry or (r.get('name') or '') != registry:
            return False
        ref_uid = r.get('uid') or ''
        return not (uid and ref_uid) or ref_uid == uid

    data = json.load(sys.stdin)
    owned = []
    hinted = []
    for item in data.get('items', []):
        meta = item.get('metadata') or {}
        name = meta.get('name') or ''
        if not name:
            continue
        refs = [r for r in (meta.get('ownerReferences') or []) if r.get('kind') == 'QuayRegistry']
        bound = ((item.get('status') or {}).get('phase') == 'Bound')
        if any(owned_by_this(r) for r in refs):
            owned.append((0 if bound else 1, name))
        elif registry and (name == registry or name.startswith(registry + '-')):
            if not any(r.get('kind') == 'QuayRegistry' and not owned_by_this(r) for r in (meta.get('ownerReferences') or [])):
                hinted.append((0 if bound else 1, name))
    pick = sorted(owned) or sorted(hinted)
    if pick:
        print(pick[0][1])
        sys.exit(0)
    sys.exit(1)
except Exception:
    traceback.print_exc()
    sys.exit(2)
") || _pickRc=$?
            if (( _pickRc == 0 )); then
                break
            elif (( _pickRc == 1 )); then
                (( $(date +%s) >= _claimDeadline )) && break
                sleep 5
                typeset -i _obcRetryRc=0
                typeset -i _claimRemain=$(( _claimDeadline - $(date +%s) ))
                (( _claimRemain > 0 )) || _claimRemain=1
                # PRRT_kwDOBHvUUM65ui2G: refreshed OBC list bounded by remaining claim budget; capture real rc not negated
                obcJson=$(timeout "${_claimRemain}s" oc get objectbucketclaim -n "${QUAY_NS}" -o json 2>"${ARTIFACT_DIR:-/tmp}/obc-err.log")
                _obcRetryRc=$?
                if (( _obcRetryRc != 0 )); then
                    _obcListErr=${_obcRetryRc}
                    _obcListMsg="$(cat "${ARTIFACT_DIR:-/tmp}/obc-err.log" 2>/dev/null || echo "oc get failed")"
                    quayObc=""
                    break
                fi
                continue
            else
                _obcPickErr=${_pickRc}
                quayObc=""
                break
            fi
        done
        if [[ -z "${quayObc}" ]]; then
            elapsed=$(( $(date +%s) - start ))
            if (( _obcListErr != 0 )); then
                RecordResult "${testName}" "failed" "ObjectBucketClaim list query failed in namespace ${QUAY_NS} (exit ${_obcListErr}: ${_obcListMsg:0:500})" "${elapsed}"
            elif (( _obcPickErr != 0 && _obcPickErr != 1 )); then
                RecordResult "${testName}" "failed" "ObjectBucketClaim selector failed in namespace ${QUAY_NS} (helper exit ${_obcPickErr}: ${quayObc:0:200})" "${elapsed}"
            else
                RecordResult "${testName}" "failed" "No ObjectBucketClaim found in Quay namespace ${QUAY_NS} after 300s timeout (selector exit 1)" "${elapsed}"
            fi
            return 1
        fi
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
    if ! obJson=$(oc get objectbucket -o json 2>"${ARTIFACT_DIR:-/tmp}/ob-err.log"); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to list ObjectBuckets: $(cat "${ARTIFACT_DIR:-/tmp}/ob-err.log" 2>/dev/null || echo "oc get failed")" "${elapsed}"
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
    ref = item.get('spec', {}).get('claimRef')
    if ref is None:
        continue
    if ref.get('name') == obc_name and ref.get('namespace') == obc_ns:
        print(item['metadata']['name'])
        sys.exit(0)
sys.exit(1)
" "${quayObc}" "${QUAY_NS}" 2>"${ARTIFACT_DIR:-/tmp}/ob-pick-err.log") || obPickRc=$?

    if (( obPickRc != 0 && obPickRc != 1 )); then
        elapsed=$(( $(date +%s) - start ))
        typeset _obPickErr=""
        _obPickErr=$(cat "${ARTIFACT_DIR:-/tmp}/ob-pick-err.log" 2>/dev/null || echo "${obName}")
        RecordResult "${testName}" "failed" "Could not resolve the ObjectBucket for Quay OBC ${quayObc} (helper exited ${obPickRc}: ${_obPickErr:0:200})" "${elapsed}"
        return 1
    fi
    if [[ -s "${ARTIFACT_DIR:-/tmp}/ob-pick-err.log" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "ObjectBucket lookup produced stderr for Quay OBC ${quayObc}" "${elapsed}"
        return 1
    fi
    if [[ -z "${obName}" ]]; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "No ObjectBucket found for Quay OBC ${quayObc}" "${elapsed}"
        return 1
    fi

    typeset pvcJson=''
    if ! pvcJson=$(oc get pvc -n "${QUAY_NS}" -o json 2>"${ARTIFACT_DIR:-/tmp}/pvc-err.log"); then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to list PVCs: $(cat "${ARTIFACT_DIR:-/tmp}/pvc-err.log" 2>/dev/null || echo "oc get failed")" "${elapsed}"
        return 1
    fi

    typeset unboundPvcs=''
    unboundPvcs=$(printf '%s' "${pvcJson}" | python3 -c "
import sys, json, os
data = json.load(sys.stdin)
quay_uid = os.environ.get('QUAY_UID', '')
items = [i for i in data.get('items', []) if any(o.get('uid')==quay_uid for o in i.get('metadata',{}).get('ownerReferences',[]))] # PRRT_kwDOBHvUUM65Mrmi: PVC via ownerReference with QUAY_UID
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
          --config <(printf 'user = "admin:%s"\n' "$(EscapeForCurlUser < "${acsPassFile}")") \
          "https://${acsHost}/v1/imageintegrations"); then
          echo "ERROR: Failed to query ACS image integrations" >&2
          exit 1
      fi

      typeset existing=''
      existing=$(printf '%s' "${response}" | python3 -c "
import sys, json, os
host = os.environ['QUAY_HOST']
data = json.load(sys.stdin)
def _norm(ep):
    ep = (ep or '').strip()
    scheme = ''
    if '://' in ep:
        scheme, ep = ep.split('://', 1)
        scheme = scheme.lower()
    ep = ep.rstrip('/')
    host_part = ep.split('/', 1)[0]
    rest = ep[len(host_part):]
    if ':' in host_part:
        h, p = host_part.rsplit(':', 1)
        if p == '443' and scheme in ('https', ''):
            host_part = h
            ep = host_part + rest
    return ep.lower()
hostNorm = _norm(host)
for i in data.get('integrations', []):
    ep = i.get('docker', {}).get('endpoint', '')
    if _norm(ep) == hostNorm:
        print(i['id'])
        sys.exit(0)
sys.exit(1)
") || existing=""

      if [[ -n "${existing}" ]]; then
          : "INFO: Quay integration already registered in ACS"
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
        # PRRT_kwDOBHvUUM65MrnB: keep TLS verification enabled; Central's own
        # configured trust (spec.central.tls.additionalCAs) is confirmed before
        # registration (PRRT_kwDOBHvUUM67E3SE), so no CA material rides the
        # payload and no insecure integration is created either way
        'insecure': False
    },
    'skipTestIntegration': True
}
print(json.dumps(payload))
")

      typeset regCode=""
      regCode=$(printf '%s' "${regPayload}" | curl -s "${acsTlsOpts[@]}" -o /dev/null -w '%{http_code}' \
          --connect-timeout 15 --max-time 60 \
          -X POST "https://${acsHost}/v1/imageintegrations" \
          --config <(printf 'user = "admin:%s"\n' "$(EscapeForCurlUser < "${acsPassFile}")") \
          -H "Content-Type: application/json" \
          -d @-) || regCode="000"
      if [[ "${regCode}" != 2* ]]; then
          echo "ERROR: Failed to register Quay in ACS (HTTP ${regCode})" >&2
          exit 1
      fi

      : "INFO: Registered Quay as ACS image integration"
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
          --config <(printf 'user = "admin:%s"\n' "$(EscapeForCurlUser < "${acsPassFile}")") \
          -H "Content-Type: application/json" \
          -d "${scanPayload}") || scanCode="000"
      if [[ "${scanCode}" != 2* ]]; then
          echo "ERROR: ACS scan request failed (HTTP ${scanCode})" >&2
          exit 1
      fi

      : "INFO: Requested ACS scan for pushed image"
    )
}

# Central's own trust configuration decides whether a TLS-verified scan can
# reach the Quay registry: Central and Scanner fetch the image, this step does
# not, so an anchor that only this step holds leaves the scan failing on the
# certificate while registration succeeds.  The Central CR is the single read
# of that configuration, and every additionalCA it carries is proved against
# the Quay endpoint with the same probe semantics ResolveQuayTlsTrust uses
# (any HTTP status other than 000 means the endpoint answered under that
# anchor).  When none of them verifies the route the caller fails the scan
# check before RegisterQuayInAcs runs, so no Quay credential is sent and no
# image integration is created.  The caller declares centralTrustReason, which
# the failure branches below fill in (dynamic scoping, as acsTlsOpts is).
function ConfirmCentralTrustsQuay () {
    typeset centralJson=''
    typeset -i centralRc=0
    centralJson="$(oc get central -n stackrox -o json 2>/dev/null)" || centralRc=$?

    # Owner-only directory: the PEM payloads come from a cluster object and
    # live only long enough to be used as curl trust anchors.
    typeset trustDir=''
    trustDir="$(mktemp -d)" || trustDir=''
    if [[ -z "${trustDir}" ]]; then
        centralTrustReason="Central's trust configuration could not be read from the Central CR in namespace stackrox (no writable temporary directory for the CA probe); no Quay integration was created"
        echo "ERROR: ${centralTrustReason}" >&2
        return 1
    fi
    chmod 0700 "${trustDir}" 2>/dev/null || true

    # One file per configured CA.  A cluster object is data, never script: the
    # payload is written to a file and handed to curl as a trust anchor, and
    # the helper only reports how the read went.  Exit 3 is an unparseable
    # response, exit 4 is no Central item: both are read failures, not "Central
    # trusts nothing", so they must not read as an absent additionalCAs list.
    typeset -i parseRc=0
    if (( centralRc == 0 )) && [[ -n "${centralJson}" ]]; then
        printf '%s' "${centralJson}" | CA_DIR="${trustDir}" python3 -c "
import json, os, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)

items = data.get('items') or []
if not items:
    sys.exit(4)

spec = items[0].get('spec') or {}
central = spec.get('central') or {}
tls = central.get('tls') or {}
count = 0
for ca in (tls.get('additionalCAs') or []):
    content = (ca or {}).get('content') or ''
    if not content.strip():
        continue
    count += 1
    with open(os.path.join(os.environ['CA_DIR'], 'central-ca-%02d.pem' % count), 'w') as fh:
        fh.write(content)
        if not content.endswith('\n'):
            fh.write('\n')
" 2>/dev/null || parseRc=$?
    fi

    if (( centralRc != 0 )) || [[ -z "${centralJson}" ]] || (( parseRc != 0 )); then
        rm -rf "${trustDir}"
        centralTrustReason="Central's trust configuration could not be read from the Central CR in namespace stackrox (oc rc=${centralRc}, helper rc=${parseRc}); no Quay integration was created"
        echo "ERROR: ${centralTrustReason}" >&2
        return 1
    fi

    typeset caFile=''
    typeset verifyingCa=''
    typeset probe=''
    for caFile in "${trustDir}"/*.pem; do
        [[ -f "${caFile}" ]] || continue
        probe="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 --cacert "${caFile}" "https://${QUAY_HOST}/v2/")" || probe='000'
        if [[ -n "${probe}" && "${probe}" != '000' ]]; then
            verifyingCa="${caFile}"
            break
        fi
    done
    rm -rf "${trustDir}"

    if [[ -n "${verifyingCa}" ]]; then
        echo "INFO: Central's configured trust verifies the Quay endpoint at ${QUAY_HOST} (spec.central.tls.additionalCAs, Central CR in namespace stackrox)" >&2
        return 0
    fi
    centralTrustReason="Central's additionalCAs do not verify the Quay route certificate for ${QUAY_HOST}; a TLS-verified scan would fail on the certificate.  Add the Quay registry CA to the Central CR (spec.central.tls.additionalCAs) before the scan can rely on verification; no Quay integration was created"
    echo "ERROR: ${centralTrustReason}" >&2
    return 1
}

# Self-test for the Central trust guard: proves that an additionalCA which
# verifies the Quay endpoint lets the flow reach registration, and that a CA
# which does not verify it, an empty additionalCAs list, or an unreadable
# Central CR fails before any registration call is made.  oc and curl are
# function stubs, so the paths need no cluster and no network, and each path
# runs the same order the scan runs (guard, then registration).
CentralTrustSelfTest() {
    typeset _origQuayHost="${QUAY_HOST:-}"
    typeset _xtraceOn=false
    if [[ "${-}" == *x* ]]; then
        _xtraceOn=true
    fi
    set +x
    export QUAY_HOST="quay-test.example.com"
    typeset _centralWithCa='{"items":[{"metadata":{"name":"stackrox-central-services","namespace":"stackrox"},"spec":{"central":{"tls":{"additionalCAs":[{"name":"quay-ca","content":"-----BEGIN CERTIFICATE-----\nSTUB\n-----END CERTIFICATE-----"}]}}}}]}'
    typeset _centralNoCa='{"items":[{"metadata":{"name":"stackrox-central-services","namespace":"stackrox"},"spec":{"central":{}}}]}'
    typeset -i _regCalls=0
    typeset -i _failures=0

    # Stub registration: records that the guarded sequence reached it.  The
    # real function is captured and restored, so running this self-test in the
    # script's own shell leaves RegisterQuayInAcs intact afterwards.
    typeset _origRegisterDef=''
    _origRegisterDef="$(declare -f RegisterQuayInAcs)"
    RegisterQuayInAcs() { _regCalls=$(( _regCalls + 1 )); return 0; }
    # The order RunAcsScan uses: the guard gates the registration call.
    _centralTrustSequence() {
        typeset centralTrustReason=''
        if ! ConfirmCentralTrustsQuay; then
            return 1
        fi
        RegisterQuayInAcs "acs.test"
        return 0
    }

    # Path 1: a configured CA verifies the Quay endpoint, registration runs.
    oc() { printf '%s' "${_centralWithCa}"; }
    curl() { printf '200'; }
    export -f oc curl
    _regCalls=0
    typeset _path1Reached=false
    if _centralTrustSequence; then
        if (( _regCalls == 1 )); then
            _path1Reached=true
        fi
    fi
    if [[ "${_path1Reached}" == true ]]; then
        echo "SELF-TEST PASS: a verified Central additionalCA lets the scan reach registration" >&2
    else
        echo "SELF-TEST FAIL: a verified Central additionalCA did not reach registration (registration calls: ${_regCalls})" >&2
        _failures=$(( _failures + 1 ))
    fi

    # Path 2: the configured CA does not verify the endpoint, no registration.
    curl() { printf '000'; }
    export -f curl
    _regCalls=0
    typeset _path2Blocked=false
    if _centralTrustSequence; then
        : "guard passed unexpectedly"
    else
        if (( _regCalls == 0 )); then
            _path2Blocked=true
        fi
    fi
    if [[ "${_path2Blocked}" == true ]]; then
        echo "SELF-TEST PASS: an additionalCA that fails the probe blocks registration" >&2
    else
        echo "SELF-TEST FAIL: an additionalCA that fails the probe did not block registration (registration calls: ${_regCalls})" >&2
        _failures=$(( _failures + 1 ))
    fi

    # Path 3: no additionalCAs configured, no registration (the probe answers,
    # so the failure is the empty trust list, not an unreachable endpoint).
    oc() { printf '%s' "${_centralNoCa}"; }
    curl() { printf '200'; }
    export -f oc curl
    _regCalls=0
    typeset _path3Blocked=false
    if _centralTrustSequence; then
        : "guard passed unexpectedly"
    else
        if (( _regCalls == 0 )); then
            _path3Blocked=true
        fi
    fi
    if [[ "${_path3Blocked}" == true ]]; then
        echo "SELF-TEST PASS: an empty additionalCAs list blocks registration" >&2
    else
        echo "SELF-TEST FAIL: an empty additionalCAs list did not block registration (registration calls: ${_regCalls})" >&2
        _failures=$(( _failures + 1 ))
    fi

    # Path 4: the Central CR cannot be read, no registration.
    oc() { return 1; }
    curl() { printf '200'; }
    export -f oc curl
    _regCalls=0
    typeset _path4Blocked=false
    if _centralTrustSequence; then
        : "guard passed unexpectedly"
    else
        if (( _regCalls == 0 )); then
            _path4Blocked=true
        fi
    fi
    if [[ "${_path4Blocked}" == true ]]; then
        echo "SELF-TEST PASS: an unreadable Central CR blocks registration" >&2
    else
        echo "SELF-TEST FAIL: an unreadable Central CR did not block registration (registration calls: ${_regCalls})" >&2
        _failures=$(( _failures + 1 ))
    fi

    # Restore the shell the self-test borrowed: no stubs (the real
    # RegisterQuayInAcs definition comes back from its captured body), the
    # original host, and tracing as it was found.
    unset -f oc curl RegisterQuayInAcs _centralTrustSequence
    if [[ -n "${_origRegisterDef}" ]]; then
        eval "${_origRegisterDef}"
    fi
    QUAY_HOST="${_origQuayHost}"
    if [[ "${_xtraceOn}" == true ]]; then
        set -x
    fi

    if (( _failures > 0 )); then
        echo "SELF-TEST FAIL: ${_failures} Central trust guard path(s) did not behave as specified" >&2
        return 1
    fi
    echo "SELF-TEST PASS: Central trust guard gates registration on Central's own configured trust" >&2
    return 0
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
    acsHost="$(oc get route -n stackrox central -o jsonpath='{.spec.host}' --ignore-not-found)" || routeRc=$?
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
    # Digest-anchored pullspec for ACS scan and polling; tag kept only as display label
    typeset acsScanTarget="${pushTarget}"
    typeset acsDigest="${quayImageDigest:-}"
    if [[ -n "${quayPushTargetDigest:-}" ]]; then
        acsScanTarget="${quayPushTargetDigest}"
    elif [[ -n "${acsDigest}" ]]; then
        typeset _acsRepo="${pushTarget}"
        if [[ "${pushTarget##*/}" == *":"* ]]; then
            _acsRepo="${pushTarget%:*}"
        fi
        acsScanTarget="${_acsRepo}@${acsDigest}"
    fi

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
    centralCa="$(oc get secret central-tls -n stackrox -o jsonpath='{.data.ca\.pem}' | base64 -d)" || centralCa=''
    typeset -a acsCaCandidates=()
    if [[ -n "${centralCa}" ]]; then
        printf '%s\n' "${centralCa}" > /tmp/acs-central-ca.crt
        acsCaCandidates+=( /tmp/acs-central-ca.crt )
    fi
    typeset ingressCaBundle=''
    ingressCaBundle="$(oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}')" || ingressCaBundle=''
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

    # Central and Scanner fetch the image, this step does not, so this step's
    # own anchor does not make the scan work: Central's configured trust is
    # confirmed before the Quay credential reaches an image integration
    # (PRRT_kwDOBHvUUM67E3SE).  A guard failure records the scan check failed
    # and returns here, so no integration is created for a scan that would
    # fail on the certificate.  The reason is taken from the guard, which
    # fills centralTrustReason in on every failure path.
    typeset centralTrustReason=''
    if ! ConfirmCentralTrustsQuay; then
        elapsed=$(( $(date +%s) - start ))
        typeset blockedReason="${centralTrustReason:-Central trust could not be confirmed}"
        RecordResult "${testName}" "failed" "ACS scan blocked: ${blockedReason}" "${elapsed}"
        rm -f "${acsPassFile}" /tmp/acs-ingress-ca.crt /tmp/acs-central-ca.crt
        return 1
    fi

    if ! RegisterQuayInAcs "${acsHost}"; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "Failed to register Quay in ACS" "${elapsed}"
        return 1
    fi
    if ! RequestAcsScan "${acsHost}" "${quayPushTargetDigest:-${acsScanTarget}}"; then
        elapsed=$(( $(date +%s) - start ))
        RecordResult "${testName}" "failed" "ACS scan request failed" "${elapsed}"
        return 1
    fi

    typeset -i acsDeadline=$(( SECONDS + 600 ))
    typeset -i attempts=0 maxAttempts=40 retryInterval=15
    typeset -i waitMinutes=$(( maxAttempts * retryInterval / 60 ))
    typeset -i answeredAttempts=0
    typeset lastQueryError=''

    while (( attempts < maxAttempts && SECONDS < acsDeadline )); do
        typeset scanResult='' scanErrFile='/tmp/acs-query.err'
        typeset -i scanRc=0
        typeset -i _acsRemain=$(( acsDeadline - SECONDS ))
        (( _acsRemain <= 5 )) && break
        typeset -i _acsMaxTime=30
        (( _acsMaxTime > _acsRemain - 5 )) && _acsMaxTime=$(( _acsRemain - 5 ))
        scanResult="$(
            set +x
            curl -fsSL "${acsTlsOpts[@]}" --connect-timeout 15 --max-time "${_acsMaxTime}" \
                --config <(printf 'user = "admin:%s"\n' "$(EscapeForCurlUser < "${acsPassFile}")") \
                "https://${acsHost}/v1/images?query=Image:${quayPushTargetDigest:-${acsScanTarget}}" 2>"${scanErrFile}"
        )" || scanRc=$?

        # The helper answers 0 (image present), 1 (image absent) or anything
        # else (helper or parse failure).  A failure must not read as "ACS did
        # not detect the image", so the three outcomes are tracked apart.
        # parseRc starts at 2: a helper that neither succeeds nor reports a
        # status is a failure, not an answered query.
        typeset -i parseRc=2
        if (( scanRc == 0 )); then
            parseRc=0
            printf '%s' "${scanResult}" | QUAY_IMAGE_DIGEST="${acsDigest}" python3 -c "
import sys, json, os
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
images = data.get('images') or []
if not images:
    sys.exit(1)
digest = os.environ.get('QUAY_IMAGE_DIGEST', '')
if digest:
    for img in images:
        if img.get('id') == digest:
            sys.exit(0)
        if digest in (img.get('name') or ''):
            sys.exit(0)
        meta = img.get('metadata') or {}
        v1 = (meta.get('v1') or {}) if isinstance(meta, dict) else {}
        if v1.get('digest') == digest or v1.get('imageDigest') == digest:
            sys.exit(0)
        if digest in str(img):
            sys.exit(0)
    sys.exit(1)
sys.exit(0)
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
            lastQueryError=$(cat "${scanErrFile}") || lastQueryError=''
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
            RequestAcsScan "${acsHost}" "${quayPushTargetDigest:-${acsScanTarget}}" || true
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
    if ! PreflightCheck; then
        echo "FATAL: Quay not reachable; skipping all tests" >&2
        RecordResult "${testNamePushPull}" "failed" "Quay registry discovery endpoint not reachable"
        RecordResult "${testNameOdf}" "skipped" "Skipped: Quay preflight (discovery endpoint) failed"
        RecordResult "${testNameAcs}" "skipped" "Skipped: Quay preflight (discovery endpoint) failed"
        exit 1
    fi
    if ! GetQuayAuth; then
        for t in "${allTests[@]}"; do
            RecordResult "${t}" "failed" "Quay credential retrieval failed"
        done
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

