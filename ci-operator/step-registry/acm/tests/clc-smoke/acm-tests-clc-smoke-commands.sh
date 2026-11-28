#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# --- JUnit carrier: one summary row on every exit path (INTEROP-9722) -------
# The cypress runner runs best-effort and its stdout is never captured into an
# artifact, so a failing smoke run used to leave the step with no JUnit row and
# nothing naming the failure. Publish exactly one JUnit document from a single
# EXIT trap, so early exits are covered as well:
#
#   ${ARTIFACT_DIR}/junit_acm-tests-clc-smoke.xml         one summary test case
#   ${SHARED_DIR}/junit/junit_acm-tests-clc-smoke.xml     one copy, as before
#
# The row passes only when the runner exited 0 and the reports directory carries
# at least one test case; every other outcome publishes a failing row whose
# message names the condition and the runner exit code. The suite name stays
# acm-tests-clc-smoke unless the lane asks for test mapping, in which case the
# component-first prefix is applied through the same conditional expression the
# clc-create/grc family uses (ADR 0007 SS2):
#
#   ${LP_QE__CR__TS_NAME__PFX__ACM:+${LP_QE__CR__TS_NAME__PFX__ACM}--}<step name>
#
# Only the exit code and the condition go into the XML: never raw runner output
# and never a credential.
typeset _carrierFile="junit_acm-tests-clc-smoke.xml"
typeset _carrierSuite="acm-tests-clc-smoke"
typeset _runnerStatus=''
typeset _carrierCondition=''
typeset _carrierCases=0

# _xml_escape STRING: escape STRING for XML text and attribute content.
_xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# _xml_root FILE: print the first element name of FILE ('testsuite',
# 'mochawesome', ...), skipping the XML declaration, comments and doctype.
_xml_root() {
    grep -m1 -oE '<[A-Za-z][A-Za-z0-9_.:-]*' -- "$1" 2>/dev/null | sed 's/^<//' || true
}

# _count_cases DIR: number of test cases in the JUnit documents under DIR. A
# document counts as JUnit when its root element is testsuite/testsuites, the
# same publication rule the clc-create step uses; anything else under reports/
# (cypress index files, html, videos) carries no test case.
_count_cases() {
    typeset _dir="$1" _f='' _root='' _n=''
    typeset -i _total=0
    if [[ -d "${_dir}" ]]; then
        while IFS= read -r -d '' _f; do
            _root="$(_xml_root "${_f}")"
            case "${_root}" in
                (testsuite|testsuites)
                    _n="$(grep -c '<testcase' -- "${_f}" || true)"
                    [[ -n "${_n}" ]] || _n=0
                    _total+=${_n}
                    ;;
            esac
        done < <(find "${_dir}" -type f -name '*.xml' -print0 | LC_ALL=C sort -z)
    fi
    printf '%s' "${_total}"
}

# _carrier_evaluate: set _carrierCondition (empty only when the run passed) and
# _carrierCases from the recorded runner status and the reports directory.
_carrier_evaluate() {
    _carrierCases=0
    _carrierCondition=''
    if [[ -z "${_runnerStatus}" ]]; then
        _carrierCondition="the step exited before the cypress runner ran"
        return 0
    fi
    if (( _runnerStatus != 0 )); then
        _carrierCondition="the cypress runner failed"
        return 0
    fi
    if [[ ! -d reports ]]; then
        _carrierCondition="the cypress runner wrote no reports directory"
        return 0
    fi
    _carrierCases="$(_count_cases reports)"
    [[ -n "${_carrierCases}" ]] || _carrierCases=0
    if (( _carrierCases == 0 )); then
        _carrierCondition="the reports directory carries zero parseable test cases"
    fi
    return 0
}

# _carrier_document NAME FAILED MESSAGE: emit the carrier document on stdout.
_carrier_document() {
    typeset _name="$1" _failed="$2" _message="$3"
    if (( _failed )); then
        cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${_name}" tests="1" failures="1" errors="0" skipped="0" time="0">
  <testcase name="${_name}: clc smoke outcome" classname="${_name}" time="0">
    <failure message="${_message}" type="clc-smoke-outcome">${_message}</failure>
  </testcase>
</testsuite>
EOF
    else
        cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${_name}" tests="1" failures="0" errors="0" skipped="0" time="0">
  <testcase name="${_name}: clc smoke outcome" classname="${_name}" time="0"/>
</testsuite>
EOF
    fi
}

# _publish_junit_carrier: write the carrier and hand one copy to SHARED_DIR.
# It runs from an EXIT trap, so it must never change the exit status: errexit
# and tracing are off inside, and every step is checked rather than fatal.
_publish_junit_carrier() {
    typeset -i _exitRc=$?
    set +ex
    _carrier_evaluate

    typeset _name="${_carrierSuite}"
    if [[ "${MAP_TESTS:-false}" == "true" ]]; then
        _name="${LP_QE__CR__TS_NAME__PFX__ACM:+${LP_QE__CR__TS_NAME__PFX__ACM}--}${_name}"
    fi
    typeset _escapedName=''
    _escapedName="$(_xml_escape "${_name}")"

    typeset -i _failed=0
    typeset _message='' _escapedMessage='' _out="${ARTIFACT_DIR}/${_carrierFile}"
    if [[ -n "${_carrierCondition}" ]]; then
        _failed=1
        if [[ -n "${_runnerStatus}" ]]; then
            _message="${_name}: ${_carrierCondition}; runner exit code ${_runnerStatus}"
        else
            _message="${_name}: ${_carrierCondition}; step exit code ${_exitRc}"
        fi
        _escapedMessage="$(_xml_escape "${_message}")"
    fi

    if ! _carrier_document "${_escapedName}" "${_failed}" "${_escapedMessage}" > "${_out}"
    then
        echo "WARNING: could not write the JUnit carrier ${_out}" >&2
        return 0
    fi
    if ! { mkdir -p "${SHARED_DIR}/junit" && cp -f "${_out}" "${SHARED_DIR}/junit/"; }
    then
        echo "WARNING: could not copy the JUnit carrier into ${SHARED_DIR}/junit" >&2
    fi
    return 0
}
trap _publish_junit_carrier EXIT

typeset secretsDir="/tmp/secrets"
typeset optionFile="./options.yaml"
typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ "${SKIP_OCP_DEPLOY:-false}" == "true" ]]; then
    cp "${secretsDir}/ci/kubeconfig" "${SHARED_DIR}/kubeconfig"
    cp "${secretsDir}/ci/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
fi

cp "${secretsDir}/clc-interop/secret-options-yaml" "${optionFile}"

if [[ -f "${awsCredFile}" ]]; then
    typeset awsAccKeyID=''
    typeset awsAccKeyToken=''

    # tracing off: AWS credentials
    set +x
    awsAccKeyID="$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")"
    awsAccKeyToken="$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")"

    if [[ -z "${awsAccKeyID}" ]] || [[ -z "${awsAccKeyToken}" ]]; then
        echo "ERROR: Failed to extract AWS credentials from ${awsCredFile}" 1>&2
        exit 1
    fi

    yq -o json eval . "${optionFile}" |
    jq -c \
          --arg awsAccKeyID "${awsAccKeyID}" \
          --rawfile awsAccKeyToken <(printf '%s' "${awsAccKeyToken}") \
        '
          .options.connections.apiKeys.aws|=(
                .awsAccessKeyID=$awsAccKeyID |
                .awsSecretAccessKeyID=($awsAccKeyToken | rtrimstr("\n"))
            )
        ' |
    yq -p json -o yaml eval . > "${optionFile}.tmp"
    mv -f "${optionFile}.tmp" "${optionFile}"
    set -x

    unset awsAccKeyID awsAccKeyToken
fi

# tracing off: kubeadmin password
set +x
export CYPRESS_OPTIONS_HUB_PASSWORD=
CYPRESS_OPTIONS_HUB_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"

typeset cypressBaseUrl=''
cypressBaseUrl="$(oc whoami --show-console)"
typeset cypressHubApiUrl=''
cypressHubApiUrl="$(oc whoami --show-server)"
typeset cypressOcpVersion=''
cypressOcpVersion="$(cat "${secretsDir}/clc/ocp_image_version")"
typeset cloudProviders=''
cloudProviders="$(cat "${secretsDir}/clc/ocp_cloud_providers")"

if [[ -z "${cypressBaseUrl}" ]] || [[ -z "${cypressHubApiUrl}" ]]; then
    echo "ERROR: Console URL or API URL is empty; oc whoami returned no usable value" 1>&2
    exit 1
fi

typeset clcStatus=0

CYPRESS_BASE_URL="${cypressBaseUrl}" \
CYPRESS_HUB_API_URL="${cypressHubApiUrl}" \
CYPRESS_CLC_OCP_IMAGE_VERSION="${cypressOcpVersion}" \
CLOUD_PROVIDERS="${cloudProviders}" \
bash +x ./execute_clc_interop_commands.sh || clcStatus=$?
set -x
_runnerStatus="${clcStatus}"

unset CYPRESS_OPTIONS_HUB_PASSWORD

# The report tree copy stays a plain tree copy: its dedup and naming are the
# INTEROP-9665 slice, not this one. It doubles as triage evidence for the run.
typeset reportStatus=0
cp -r reports "${ARTIFACT_DIR}/" || reportStatus=$?

# Carrier decision (INTEROP-9722). The EXIT trap publishes the row; this only
# decides the exit status, so a run that carries no parseable test case can no
# longer stay green.
_carrier_evaluate
typeset stepStatus=0
if (( clcStatus != 0 )); then
    stepStatus="${clcStatus}"
elif (( reportStatus != 0 )); then
    stepStatus="${reportStatus}"
elif [[ -n "${_carrierCondition}" ]]; then
    stepStatus=1
fi
exit "${stepStatus}"
