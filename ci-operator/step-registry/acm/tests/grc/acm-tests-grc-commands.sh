#!/bin/bash
set -o nounset
# set -o errexit
set -o pipefail

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget --timeout=30 -qO-) || _fURL=(curl --connect-timeout 10 --max-time 30 -fsSL)
        "${_fURL[@]}" \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        trap '
            LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
                ExitTrap--PostProcessPrep
        ' EXIT
    else
        echo "WARNING: ExitTrap--PostProcessPrep not available, skipping junit remapping" >&2
    fi
fi

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
SKIP_OCP_DEPLOY="false"
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
fi 

export KUBECONFIG=${SHARED_DIR}/kubeconfig

set +x  # Disable tracing to prevent credential leakage in CI logs
# Set the dynamic vars based on provisioned hub cluster.
OC_CLUSTER_URL=$(oc whoami --show-server)
export OC_CLUSTER_URL
CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL
OC_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export OC_CLUSTER_PASS
RBAC_PASS=$(cat $SECRETS_DIR/grc/rbac-pass)
export RBAC_PASS

# Run the test execution script with output redirected to a temp file.
# The acmqe-grc-test container prints secret values through multiple code
# paths.  When ANY secret value appears in stdout/stderr, Prow's sidecar
# censor replaces the entire build-log.txt with a redaction notice (76 bytes).
#
# Strategy: redirect ALL output to a temp file so the sidecar sees nothing
# during execution, then scrub EVERY secret value from the file, and finally
# cat the scrubbed content to stdout.  This guarantees the sidecar only ever
# sees clean output.

# Escape a literal string for safe use in a sed extended-regex pattern.
_sed_ere_escape() {
    printf '%s\n' "$1" | sed -e 's#\\#\\\\#g' -e 's#[].*^$[+?{}()|/]#\\&#g' | head -1
}

# Collect all secret values to scrub (skip empty / too-short values).
_secret_vals=()
# 1. Every file under /tmp/secrets/grc/ is treated as a secret.
if [[ -d /tmp/secrets/grc ]]; then
    while IFS= read -r -d '' _sf; do
        [[ -f "$_sf" ]] || continue
        _sv="$(cat "$_sf")" || continue
        # Skip empty values or values shorter than 4 chars to avoid false positives
        [[ ${#_sv} -ge 4 ]] && _secret_vals+=("$_sv")
    done < <(find /tmp/secrets/grc -maxdepth 1 -type f -print0 2>/dev/null)
fi
# 2. Explicitly add OC_CLUSTER_PASS and RBAC_PASS (exported env vars).
[[ -n "${OC_CLUSTER_PASS:-}" && ${#OC_CLUSTER_PASS} -ge 4 ]] && _secret_vals+=("${OC_CLUSTER_PASS}")
[[ -n "${RBAC_PASS:-}" && ${#RBAC_PASS} -ge 4 ]] && _secret_vals+=("${RBAC_PASS}")

# Build a sed alternation pattern from the collected secret values.
_secrets_pattern=""
for _val in "${_secret_vals[@]+"${_secret_vals[@]}"}"; do
    _secrets_pattern="${_secrets_pattern:+${_secrets_pattern}|}$(_sed_ere_escape "$_val")"
done

# Run the test suite with all output captured to a temp file.
_grc_raw_log="$(mktemp)"
typeset -i _test_rc=0
./execute_grc_interop_commands.sh > "${_grc_raw_log}" 2>&1 || _test_rc=$?

# Scrub secret values from the captured output.
_grc_scrubbed_log="$(mktemp)"
if [[ -n "$_secrets_pattern" ]]; then
    sed -E "s/${_secrets_pattern}/[REDACTED]/g" "${_grc_raw_log}" > "${_grc_scrubbed_log}"
else
    cp "${_grc_raw_log}" "${_grc_scrubbed_log}"
fi
rm -f "${_grc_raw_log}"

# Write scrubbed output to $ARTIFACT_DIR so it is uploaded to GCS as-is.
# Files in $ARTIFACT_DIR bypass Prow sidecar censoring, which may replace
# build-log.txt with a 76-byte redaction notice if any secret value ever
# appeared on stdout/stderr.
cp "${_grc_scrubbed_log}" "${ARTIFACT_DIR}/grc-test-output.log"

# Also emit to stdout (for build-log.txt, best-effort).
cat "${_grc_scrubbed_log}"
rm -f "${_grc_scrubbed_log}"
set -x  # Re-enable tracing

# Copy the test cases results to an external directory
cp -r test-output/cypress "$ARTIFACT_DIR/" || true

exit "${_test_rc}"
