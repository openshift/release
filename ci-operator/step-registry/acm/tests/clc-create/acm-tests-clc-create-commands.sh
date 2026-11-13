#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# --- Variables ---
typeset secretsDir="/tmp/secrets"
typeset optionFile="./options.yaml"
typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"

# --- JUnit carrier: suite-name remap wiring (INTEROP-9665, INTEROP-9580) ---
# The cypress runner emits one JUnit document per spec (and republishes the
# same bytes under several report paths) whose suite names are the spec's
# cypress describe blocks ("Root Suite", "create clusters", ...). Those names
# match no registered CR matcher, so attribution lands on Unknown. When the
# lane asks for test mapping, merge the reports into one document and rename
# every suite component-first per ADR 0007 SS2:
#
#   lp-interop--ACM--OPP--<original suite name>
#
# The prefix is lane-driven ($LP_QE__CR__TS_NAME__PFX__ACM), not baked: this
# step is shared with lanes that must keep their unprefixed names. Same wiring
# as acm-tests-grc / acm-tests-alc (openshift/release#87932).
if [[ "${MAP_TESTS:-false}" == "true" ]]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget --timeout=30 -qO-) || _fURL=(curl --connect-timeout 10 --max-time 30 -fsSL)
        "${_fURL[@]}" \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        trap '
            LP_IO__ET_PPP__NEW_TS_NAME="${LP_QE__CR__TS_NAME__PFX__ACM:+${LP_QE__CR__TS_NAME__PFX__ACM}--}%s" \
                ExitTrap--PostProcessPrep
        ' EXIT
    else
        echo "WARNING: ExitTrap--PostProcessPrep not available, skipping junit remapping" >&2
    fi
fi

# Get the creds from ACMQE CI vault and run the automation on pre-existing HUB
if [[ "${SKIP_OCP_DEPLOY:-false}" == "true" ]]; then
    : "------------ Skipping OCP Deploy = ${SKIP_OCP_DEPLOY} ------------"
    cp "${secretsDir}/ci/kubeconfig" "${SHARED_DIR}/kubeconfig"
    cp "${secretsDir}/ci/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
fi

cp "${secretsDir}/clc-interop/secret-options-yaml" "${optionFile}"

# Update the AWS credentials in options.yaml from cluster profile
if [[ -f "${awsCredFile}" ]]; then
    typeset awsAccKeyID=
    typeset awsAccKeyToken=

    set +x
    awsAccKeyID="$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")"
    awsAccKeyToken="$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")"

    [ -n "${awsAccKeyID}" ] && [ -n "${awsAccKeyToken}" ]

    echo "Updating credentials in ${optionFile}..."
    yq -o json eval . "${optionFile}" |
    jq -c \
          --arg awsAccKeyID "${awsAccKeyID}" \
          --arg awsAccKeyToken "${awsAccKeyToken}" \
        '
          .options.connections.apiKeys.aws|=(
                .awsAccessKeyID=$awsAccKeyID |
                .awsSecretAccessKeyID=$awsAccKeyToken
            )
        ' |
    yq -p json -o yaml eval . > "${optionFile}.tmp"
    mv -f "${optionFile}.tmp" "${optionFile}"
    set -x

    unset awsAccKeyID awsAccKeyToken
fi

: "Executing CLC interop commands..."
set +x
export CYPRESS_OPTIONS_HUB_PASSWORD=
CYPRESS_OPTIONS_HUB_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
set -x

set +x
typeset -i _test_rc=0
CYPRESS_BASE_URL="$(oc whoami --show-console)" \
CYPRESS_HUB_API_URL="$(oc whoami --show-server)" \
CYPRESS_CLC_OCP_IMAGE_VERSION="$(cat "${secretsDir}/clc/ocp_image_version")" \
CLOUD_PROVIDERS="$(cat "${secretsDir}/clc/ocp_cloud_providers")" \
bash +x ./execute_clc_interop_commands.sh || _test_rc=$?
set -x

unset CYPRESS_OPTIONS_HUB_PASSWORD

# ---------------------------------------------------------------------------
# Single-copy publication (INTEROP-9665, INTEROP-9580)
#
# The cypress runner writes the same JUnit document under several report
# paths (a flat one and a per-spec directory), so a plain `cp -r reports`
# republishes every unique document up to four times and the spyglass lens
# shows each suite repeatedly. Publish by content instead:
#
#   * JUnit documents (root element testsuite/testsuites) -> ${ARTIFACT_DIR}/junit/
#   * every other report file (videos, screenshots, html, json, non-JUnit
#     xml)                                                 -> ${ARTIFACT_DIR}/reports/
#
# Each unique content hash is published exactly once. The publication name is
# the path relative to reports/ with '/' rendered as '__', so it is stable
# across runs and still identifies the spec. Duplicated content keeps the first
# path in byte order (LC_ALL=C): the flat reports/<spec>.xml therefore wins
# over the reports/<spec>/ directory copy, because '.' sorts before '/'.
# ---------------------------------------------------------------------------
: "Publishing artifacts (one copy per unique report document)..."
typeset _reportsDir="reports"
typeset _junitDir="${ARTIFACT_DIR}/junit"
typeset _triageDir="${ARTIFACT_DIR}/reports"
typeset -i _published_cases=0
typeset -i _published_junit=0
typeset -A _seenContent=()
mkdir -p "${_junitDir}" "${_triageDir}"

# _xml_root FILE: print the first element name of FILE ('testsuite',
# 'testsuites', ...), skipping the XML declaration, comments and doctype.
_xml_root() {
    grep -m1 -oE '<[A-Za-z][A-Za-z0-9_.:-]*' -- "$1" 2>/dev/null | sed 's/^<//' || true
}

# _relname PATH: stable publication file name for a path under reports/.
_relname() {
    typeset _r="${1#"${_reportsDir}"/}"
    printf '%s' "${_r//\//__}"
}

if [[ -d "${_reportsDir}" ]]; then
    while IFS= read -r -d '' _f; do
        _sum="$(sha256sum -- "$_f")"
        _sum="${_sum%% *}"
        if [[ -n "${_seenContent[${_sum}]:-}" ]]; then
            : "Skipping duplicate report document ${_f}"
            continue
        fi
        _seenContent["${_sum}"]=1
        _root="$(_xml_root "$_f")"
        case "${_root}" in
            (testsuite|testsuites)
                _out="${_junitDir}/$(_relname "$_f")"
                cp -f -- "$_f" "${_out}"
                _cnt=0
                _cnt="$(grep -c '<testcase' -- "${_out}" || true)"
                if [[ -n "${_cnt}" ]]; then
                    _published_cases+=${_cnt}
                fi
                _published_junit+=1
                ;;
            (*)
                _out="${_triageDir}/$(_relname "$_f")"
                mkdir -p -- "$(dirname -- "${_out}")"
                cp -f -- "$_f" "${_out}"
                ;;
        esac
    done < <(find "${_reportsDir}" -type f -print0 | LC_ALL=C sort -z)
else
    echo "WARNING: no ${_reportsDir}/ directory present; publishing zero test cases" >&2
fi

: "Published ${_published_junit} unique JUnit document(s) carrying ${_published_cases} test case(s)."

# ---------------------------------------------------------------------------
# Assertiveness floor plus carrier guarantee (INTEROP-9665; INTEROP-9598
# precedent in acm-tests-alc). A green step that publishes no test case makes
# prow render nothing, and a step that publishes an empty carrier asserts
# nothing. Whenever no published JUnit document carries a test case, add one
# failing row that names the condition and fail the step. The row's suite name
# is the step name so the EXIT trap prefixes it when the remap is active.
# Only the condition and the runner exit code go into the XML: never raw
# runner output and never a credential.
# ---------------------------------------------------------------------------
# _xml_escape STRING: escape STRING for XML text and attribute content.
_xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

if ((_published_cases == 0)); then
    if [[ ! -d "${_reportsDir}" ]]; then
        _carrierCondition="the runner wrote no reports directory"
    elif ((_published_junit == 0)); then
        _carrierCondition="the runner wrote no JUnit report, or the reports carry zero test cases"
    else
        _carrierCondition="the reports carry zero test cases"
    fi
    _carrierMessage="acm-tests-clc-create published no test case (${_carrierCondition}); runner exit code ${_test_rc}"
    _carrierMessageEsc="$(_xml_escape "${_carrierMessage}")"
    cat > "${_junitDir}/acm-tests-clc-create-empty-carrier.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="acm-tests-clc-create" tests="1" failures="1" errors="0" skipped="0">
  <testcase name="acm-tests-clc-create: runner asserted nothing" classname="acm-tests-clc-create">
    <failure message="${_carrierMessageEsc}" type="empty-junit-carrier">${_carrierMessageEsc}. The cluster lifecycle suite produced no parseable test case, so this step asserted nothing; see the step build log for the runner failure (INTEROP-9665).</failure>
  </testcase>
</testsuite>
EOF
    echo "ERROR: ${_carrierMessage}; failing the step and recording a JUnit row that names it (INTEROP-9665)." >&2
    if ((_test_rc == 0)); then
        _test_rc=1
    fi
fi

exit "${_test_rc}"
