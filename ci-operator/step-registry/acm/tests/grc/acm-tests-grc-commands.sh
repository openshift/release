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

# ---------------------------------------------------------------------------
# Scrub strategy
# ---------------------------------------------------------------------------
# CI artifacts pass through TWO independent censoring layers:
#
#   1. Prow sidecar (pre-upload): replaces ~128 known secret values inline.
#      If ANY value is found in build-log.txt the ENTIRE file is replaced
#      with a 76-byte "potentially sensitive information" notice.
#
#   2. leaktk-gcs-filter (post-upload): an InfoSec Cloud Function that runs
#      PATTERN-based detection (Authorization headers, bearer tokens, JWT
#      tokens, PEM blocks, AWS key patterns, JSON keys named "password" /
#      "secret" / "token") and replaces ENTIRE matching files.
#
# To survive both layers we perform two scrub passes:
#   Pass 1 - VALUE-BASED: replace every known secret literal collected from
#            Vault mounts, kubeconfig tokens, and SA tokens.
#   Pass 2 - PATTERN-BASED: replace common leaktk trigger patterns regardless
#            of whether we know the exact value.
# ---------------------------------------------------------------------------

# Escape a literal string for safe use in a sed extended-regex pattern.
_sed_ere_escape() {
    printf '%s\n' "$1" | sed -e 's#\\#\\\\#g' -e 's#[].*^$[+?{}()|/]#\\&#g' | head -1
}

# Collect all secret values to scrub (skip empty / too-short values).
_secret_vals=()

# 1. Every file under ALL /tmp/secrets/ subdirectories is treated as a secret
#    (covers grc-credentials at /tmp/secrets/grc AND ci-secrets at
#    /tmp/secrets/ci, plus any future mounts).
if [[ -d /tmp/secrets ]]; then
    while IFS= read -r -d '' _sf; do
        [[ -f "$_sf" ]] || continue
        # Process every line of each secret file separately;
        # multi-line files (certificates, keys) need each line scrubbed.
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            [[ ${#_line} -ge 4 ]] && _secret_vals+=("$_line")
        done < "$_sf"
    done < <(find /tmp/secrets -type f -print0 2>/dev/null)
fi

# 2. Explicitly add OC_CLUSTER_PASS and RBAC_PASS (exported env vars).
[[ -n "${OC_CLUSTER_PASS:-}" && ${#OC_CLUSTER_PASS} -ge 4 ]] && _secret_vals+=("${OC_CLUSTER_PASS}")
[[ -n "${RBAC_PASS:-}" && ${#RBAC_PASS} -ge 4 ]] && _secret_vals+=("${RBAC_PASS}")

# 3. Extract bearer tokens from kubeconfig (these are NOT in Vault files but
#    are generated during cluster provisioning and end up in kubeconfig).
if [[ -f "${KUBECONFIG:-}" ]]; then
    while IFS= read -r _kt; do
        [[ ${#_kt} -ge 4 ]] && _secret_vals+=("$_kt")
    done < <(sed -n 's/^[[:blank:]]*token:[[:blank:]]*//p' "${KUBECONFIG}" 2>/dev/null || true)
fi

# 4. ServiceAccount token mounted by Kubernetes into every pod.
_sa_token_file="/var/run/secrets/kubernetes.io/serviceaccount/token"
if [[ -f "$_sa_token_file" ]]; then
    _sa_token="$(cat "$_sa_token_file" 2>/dev/null)" || true
    [[ -n "${_sa_token:-}" && ${#_sa_token} -ge 4 ]] && _secret_vals+=("$_sa_token")
    unset _sa_token
fi

# Build a sed alternation pattern from the collected secret values.
_secrets_pattern=""
for _val in "${_secret_vals[@]+"${_secret_vals[@]}"}"; do
    _secrets_pattern="${_secrets_pattern:+${_secrets_pattern}|}$(_sed_ere_escape "$_val")"
done

# Run the test suite with all output captured to a temp file.
_grc_raw_log="$(mktemp)"
typeset -i _test_rc=0
./execute_grc_interop_commands.sh > "${_grc_raw_log}" 2>&1 || _test_rc=$?

# --- Pass 1: VALUE-BASED scrub (known secret literals) --------------------
_grc_scrubbed_log="$(mktemp)"
if [[ -n "$_secrets_pattern" ]]; then
    sed -E "s/${_secrets_pattern}/[REDACTED]/g" "${_grc_raw_log}" > "${_grc_scrubbed_log}"
else
    cp "${_grc_raw_log}" "${_grc_scrubbed_log}"
fi
rm -f "${_grc_raw_log}"

# --- Pass 2: PATTERN-BASED scrub (leaktk-gcs-filter triggers) -------------
# NOTE: The sed patterns below deliberately use character-class tricks like
# "Authorizatio[n]" so that the patterns do not match THEMSELVES when
# ci-operator embeds this script in pods.json / pod spec, which leaktk also
# scans.
_grc_pattern_scrubbed="$(mktemp)"
sed -E \
    -e 's|(Authorizatio[n]:[[:blank:]]*([Bb]earer[[:blank:]]+)?)[A-Za-z0-9._~+/=-]{16,}|\1[REDACTED]|g' \
    -e 's|([Bb]eare[r][[:blank:]]+)[A-Za-z0-9._~+/=-]{16,}|\1[REDACTED]|g' \
    -e 's|(toke[n]=[[:blank:]]*)([A-Za-z0-9._~+/=-]{16,})|\1[REDACTED]|g' \
    -e 's|-----BEGI[N] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)[-----]+|[REDACTED:PEM-HEADER]|g' \
    -e 's|-----EN[D] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)[-----]+|[REDACTED:PEM-FOOTER]|g' \
    -e 's#("[A-Za-z0-9_-]*(passwo[r]d|secre[t]|toke[n]|beare[r]|credentia[l])(_?(key|code))?[[:blank:]]*"[[:blank:]]*:[[:blank:]]*")([^"\\]|\\.)+#\1[REDACTED]#Ig' \
    "${_grc_scrubbed_log}" > "${_grc_pattern_scrubbed}"
mv "${_grc_pattern_scrubbed}" "${_grc_scrubbed_log}"

# Write scrubbed output to $ARTIFACT_DIR so it is uploaded to GCS.
# NOTE: Files in $ARTIFACT_DIR are still subject to BOTH censoring layers
# (Prow sidecar inline replacement AND leaktk-gcs-filter post-upload
# pattern scan).  The scrubbing above is required to prevent either layer
# from replacing the entire file with the 76-byte redaction notice.
cp "${_grc_scrubbed_log}" "${ARTIFACT_DIR}/grc-test-output.log"

# Also emit to stdout (for build-log.txt, best-effort).
cat "${_grc_scrubbed_log}"
rm -f "${_grc_scrubbed_log}"
set -x  # Re-enable tracing

# Copy the test cases results to an external directory
cp -r test-output/cypress "$ARTIFACT_DIR/" || true

# Broaden JUnit/XML collection: search for any XML result files that may live
# outside the cypress/ subtree (e.g. mocha, jest, or custom reporters).
set +x  # sed patterns reference escaped secret values
find test-output -name '*.xml' -not -path 'test-output/cypress/*' -print0 2>/dev/null | \
    while IFS= read -r -d '' _xml; do
        _xml_tmp="$(mktemp)"
        # Pass 1: value-based scrub
        if [[ -n "$_secrets_pattern" ]]; then
            sed -E "s/${_secrets_pattern}/[REDACTED]/g" "$_xml" > "$_xml_tmp"
        else
            cp "$_xml" "$_xml_tmp"
        fi
        # Pass 2: pattern-based scrub
        sed -E -i \
            -e 's|(Authorizatio[n]:[[:blank:]]*([Bb]earer[[:blank:]]+)?)[A-Za-z0-9._~+/=-]{16,}|\1[REDACTED]|g' \
            -e 's|([Bb]eare[r][[:blank:]]+)[A-Za-z0-9._~+/=-]{16,}|\1[REDACTED]|g' \
            -e 's|(toke[n]=[[:blank:]]*)([A-Za-z0-9._~+/=-]{16,})|\1[REDACTED]|g' \
            -e 's|-----BEGI[N] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)[-----]+|[REDACTED:PEM-HEADER]|g' \
            -e 's|-----EN[D] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)[-----]+|[REDACTED:PEM-FOOTER]|g' \
            -e 's#("[A-Za-z0-9_-]*(passwo[r]d|secre[t]|toke[n]|beare[r]|credentia[l])(_?(key|code))?[[:blank:]]*"[[:blank:]]*:[[:blank:]]*")([^"\\]|\\.)+#\1[REDACTED]#Ig' \
            "$_xml_tmp"
        cp --backup=numbered "$_xml_tmp" "$ARTIFACT_DIR/$(basename "$_xml")"
        rm -f "$_xml_tmp"
    done || true
set -x

exit "${_test_rc}"
