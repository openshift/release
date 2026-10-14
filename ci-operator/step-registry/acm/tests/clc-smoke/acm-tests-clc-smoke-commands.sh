#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# --- Typed exit globals (INTEROP-9527) ---
_JUNIT_KIND=""
_JUNIT_MESSAGE=""
_EXIT_CLASS=""    # "product" or "infra"

# shellcheck disable=SC2317
_propagate_junit () {
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
}

# --- Atomic JUnit Writer (INTEROP-9527) ---
# shellcheck disable=SC2317
_junit_emit_safe() {
  local kind="$1" message="$2" rc="${3:-0}"
  local tmpf
  tmpf="${ARTIFACT_DIR}/.junit_lp-interop--OPP--acm-clc-smoke.tmp.$$"
  {
    cat <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="lp-interop--OPP--acm-clc-smoke" tests="1" failures="$( (( rc != 0 )) && echo 1 || echo 0)">
  <testcase name="${kind}">
    $( (( rc != 0 )) && printf '<failure message="%s">exit code %d</failure>' "${message}" "${rc}" )
  </testcase>
</testsuite>
XMLEOF
  } > "${tmpf}"
  mv -f "${tmpf}" "${ARTIFACT_DIR}/junit_lp-interop--OPP--acm-clc-smoke.xml"
  if [[ -n "${SHARED_DIR:-}" ]]; then
    mkdir -p "${SHARED_DIR}/junit" 2>/dev/null || true
    cp "${ARTIFACT_DIR}/junit_lp-interop--OPP--acm-clc-smoke.xml" "${SHARED_DIR}/junit/" 2>/dev/null || true
  fi
}

# --- Single typed finalizer (INTEROP-9527) ---
# shellcheck disable=SC2317
_finalize_exit() {
  local rc=$?
  set +e
  # Fallback for unclassified exits
  if [[ -z "${_JUNIT_KIND}" && "${rc}" -ne 0 ]]; then
    _JUNIT_KIND="unclassified-failure"
    _JUNIT_MESSAGE="Script exited with code ${rc} before classification"
    _EXIT_CLASS="infra"
  fi
  if [[ -n "${_JUNIT_KIND}" ]]; then
    _junit_emit_safe "${_JUNIT_KIND}" "${_JUNIT_MESSAGE}" "${rc}"
  fi
  _propagate_junit
  exit "${rc}"
}
trap '_finalize_exit' EXIT

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

unset CYPRESS_OPTIONS_HUB_PASSWORD

typeset reportStatus=0
cp -r reports "${ARTIFACT_DIR}/" || reportStatus=$?
if (( clcStatus != 0 )); then
    exit "${clcStatus}"
fi
exit "${reportStatus}"
