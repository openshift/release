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
            LP_IO__ET_PPP__NEW_TS_NAME="${LP_QE__CR__TS_NAME__PFX__ACM:+${LP_QE__CR__TS_NAME__PFX__ACM}--}%s" \
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

# Apply pattern-based scrub rules that target leaktk-gcs-filter trigger patterns.
# Usage: _scrub_leaktk_patterns FILE          (writes to stdout)
#        _scrub_leaktk_patterns -i FILE       (edits file in place)
_scrub_leaktk_patterns() {
    local _sed_opts=("-E")
    if [[ "${1:-}" == "-i" ]]; then
        _sed_opts+=("-i")
        shift
    fi
    sed "${_sed_opts[@]}" \
        -e 's|(Authorizatio[n]:[[:blank:]]*([Bb]earer[[:blank:]]+)?)[A-Za-z0-9._~+/=-]{16,}|\1[REDACTED]|g' \
        -e 's|([Bb]eare[r][[:blank:]]+)[A-Za-z0-9._~+/=-]{16,}|\1[REDACTED]|g' \
        -e 's|(toke[n]=[[:blank:]]*)([A-Za-z0-9._~+/=-]{16,})|\1[REDACTED]|g' \
        -e 's#-----BEGI[N] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)-----#[REDACTED:PEM-HEADER]#g' \
        -e 's#-----EN[D] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)-----#[REDACTED:PEM-FOOTER]#g' \
        -e 's#("[A-Za-z0-9_-]*(passwo[r]d|secre[t]|toke[n]|beare[r]|credentia[l])(_?(key|code))?[[:blank:]]*"[[:blank:]]*:[[:blank:]]*")([^"\\]|\\.)+#\1[REDACTED]#Ig' \
        "$1"
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
    done < <(find /tmp/secrets -type f -size -1M -print0 2>/dev/null)
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

# --- OPP placement snapshot (INTEROP-9711) --------------------------------
# The GRC suite relabels managedclusters/local-cluster into the global
# cluster set mid-run (audit event 5e5e5c9e on the 2026-11-11 OPP
# rehearsals). That empties the OPP placement, removes the replicated
# policies, and deletes the OperatorPolicy templates while the operators
# stay installed. Snapshot the OPP-relevant state BEFORE the suite so the
# post-suite block can restore the labels and assert the placement, and so
# the operator-policy inventory is captured before the detachment point
# instead of only in the late must-gather. Self-scoping: active only when
# the OPP placement exists, so other consumers of this step are unaffected.
_OPP_PLACEMENT_NS="open-cluster-management-global-set"
_OPP_PLACEMENT_NAME="placement-openshift-plus-hub"
_OPP_MC_NAME="local-cluster"
_OPP_LABEL_KEYS=("local-cluster" "cluster.open-cluster-management.io/clusterset" "cluster.open-cluster-management.io/clustersets")
_OPP_EVIDENCE_DIR="${ARTIFACT_DIR}/olm-evidence-pre-grc"
typeset -i _OPP_ACTIVE=0
typeset -i _OPP_POLICY_COUNT=-1
if oc get placement "-n${_OPP_PLACEMENT_NS}" "${_OPP_PLACEMENT_NAME}" >/dev/null 2>&1; then
    _OPP_ACTIVE=1
    mkdir -p "${_OPP_EVIDENCE_DIR}"
    # 1. OperatorPolicy inventory (targeted extraction, INTEROP-9525 style:
    #    name + conditions only, no full resource dumps).
    oc get operatorpolicy -A -o json 2>/dev/null | \
        python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "conditions": i.get("status", {}).get("conditions")
    })
print(json.dumps(result, indent=2))
' > "${_OPP_EVIDENCE_DIR}/01-operatorpolicy.json" 2>&1
    _OPP_POLICY_COUNT="$(python3 -c '
import json, sys
try:
    print(len(json.load(open(sys.argv[1]))))
except Exception:
    print(-1)
' "${_OPP_EVIDENCE_DIR}/01-operatorpolicy.json")"
    echo "${_OPP_POLICY_COUNT}" > "${_OPP_EVIDENCE_DIR}/00-operatorpolicy-count.txt"
    # 2. local-cluster labels (the restore baseline for the post-suite block).
    oc get managedcluster "${_OPP_MC_NAME}" -o json 2>/dev/null | \
        python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({
    "name": d["metadata"]["name"],
    "labels": d["metadata"].get("labels", {})
}, indent=2))
' > "${_OPP_EVIDENCE_DIR}/02-managedcluster-labels.json" 2>&1
    # 3. Placement status (pre-suite decisions).
    oc get placement "-n${_OPP_PLACEMENT_NS}" "${_OPP_PLACEMENT_NAME}" -o json 2>/dev/null | \
        python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({
    "name": d["metadata"]["name"],
    "namespace": d["metadata"]["namespace"],
    "status": d.get("status", {})
}, indent=2))
' > "${_OPP_EVIDENCE_DIR}/03-placement-status.json" 2>&1
    # Scrub the snapshot files (both passes) before they land in artifacts.
    # Tracing is already off in this section; keep it off for the suite run.
    for _opp_f in "${_OPP_EVIDENCE_DIR}"/*.json; do
        [[ -f "${_opp_f}" ]] || continue
        _opp_tmp="$(mktemp)"
        if [[ -n "${_secrets_pattern}" ]]; then
            sed -E "s/${_secrets_pattern}/[REDACTED]/g" "${_opp_f}" > "${_opp_tmp}" || cp "${_opp_f}" "${_opp_tmp}"
        else
            cp "${_opp_f}" "${_opp_tmp}"
        fi
        _scrub_leaktk_patterns -i "${_opp_tmp}"
        mv "${_opp_tmp}" "${_opp_f}"
    done
    echo "OPP snapshot taken: ${_OPP_POLICY_COUNT} OperatorPolicy objects; labels and placement state in ${_OPP_EVIDENCE_DIR}"
fi

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
if ! _scrub_leaktk_patterns "${_grc_scrubbed_log}" > "${_grc_pattern_scrubbed}"; then
    echo "ERROR: pattern-based scrub (Pass 2) failed; keeping Pass-1 log to avoid data loss" >&2
    rm -f "${_grc_pattern_scrubbed}"
else
    mv "${_grc_pattern_scrubbed}" "${_grc_scrubbed_log}"
fi

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

# Scrub cypress test results before copying to ARTIFACT_DIR
set +x  # sed patterns reference escaped secret values
find test-output/cypress -type f -print0 2>/dev/null | \
    while IFS= read -r -d '' _cy; do
        _cy_tmp="$(mktemp)"
        # Pass 1: value-based scrub
        if [[ -n "$_secrets_pattern" ]]; then
            sed -E "s/${_secrets_pattern}/[REDACTED]/g" "$_cy" > "$_cy_tmp"
        else
            cp "$_cy" "$_cy_tmp"
        fi
        # Pass 2: pattern-based scrub
        _scrub_leaktk_patterns -i "$_cy_tmp"
        _cy_rel="${_cy#test-output/}"
        mkdir -p "$ARTIFACT_DIR/$(dirname "$_cy_rel")"
        cp "$_cy_tmp" "$ARTIFACT_DIR/$_cy_rel"
        rm -f "$_cy_tmp"
    done
set -x

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
        _scrub_leaktk_patterns -i "$_xml_tmp"
        cp --backup=numbered "$_xml_tmp" "$ARTIFACT_DIR/$(basename "$_xml")"
        rm -f "$_xml_tmp"
    done
set -x

# --- OPP placement restore and assert (INTEROP-9711) ----------------------
# Restore the local-cluster labels the GRC suite may have changed (the
# exclusive clusterset label was moved to global mid-suite), wait for the
# OPP placement to re-select local-cluster, and record both checks as JUnit
# rows so prow and the run gates see the outcome. The emitted suite name is
# short; on lanes with MAP_TESTS=true the ExitTrap merge prefixes it with
# the Component Readiness prefix for this step.
if [[ "${_OPP_ACTIVE}" -eq 1 ]]; then
    _opp_xesc() {
        printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
    }
    # Restore drifted OPP-relevant labels from the pre-suite snapshot.
    {
        echo "=== OPP label restore $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
        for _opp_key in "${_OPP_LABEL_KEYS[@]}"; do
            _opp_pre="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get("labels", {}).get(sys.argv[2])
    print(v if v is not None else "")
except Exception:
    print("")
' "${_OPP_EVIDENCE_DIR}/02-managedcluster-labels.json" "${_opp_key}")"
            _opp_cur="$(oc get managedcluster "${_OPP_MC_NAME}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d["metadata"].get("labels", {}).get(sys.argv[1])
    print(v if v is not None else "")
except Exception:
    print("")
' "${_opp_key}")"
            if [[ "${_opp_pre}" != "${_opp_cur}" ]]; then
                echo "restoring label ${_opp_key}: '${_opp_cur}' -> '${_opp_pre}'"
                if [[ -z "${_opp_pre}" ]]; then
                    oc label managedclusters "${_OPP_MC_NAME}" "${_opp_key}-" --overwrite 2>&1 || true
                else
                    oc label managedclusters "${_OPP_MC_NAME}" "${_opp_key}=${_opp_pre}" --overwrite 2>&1 || true
                fi
            fi
        done
    } > "${_OPP_EVIDENCE_DIR}/04-label-restore.log" 2>&1

    # Wait (bounded, up to 5 minutes) for the placement to re-select
    # local-cluster after the label restore.
    typeset -i _opp_sel=0
    typeset -i _opp_try=0
    while (( _opp_try < 30 )); do
        _opp_dec="$(oc get placement "-n${_OPP_PLACEMENT_NS}" "${_OPP_PLACEMENT_NAME}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    s = d.get("status", {})
    names = s.get("clusterNames")
    if names is None:
        names = [x.get("clusterName") for x in s.get("decisions", []) or []]
    print("yes" if "local-cluster" in [n for n in names if n] else "no")
except Exception:
    print("no")
')"
        if [[ "${_opp_dec}" == "yes" ]]; then
            _opp_sel=1
            break
        fi
        _opp_try=$((_opp_try + 1))
        sleep 10
    done

    # Post-suite placement state as evidence.
    oc get placement "-n${_OPP_PLACEMENT_NS}" "${_OPP_PLACEMENT_NAME}" -o json 2>/dev/null | \
        python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({
    "name": d["metadata"]["name"],
    "namespace": d["metadata"]["namespace"],
    "status": d.get("status", {})
}, indent=2))
' > "${_OPP_EVIDENCE_DIR}/05-placement-status-post.json" 2>&1

    # JUnit rows for both checks (INTEROP-9711 done-when evidence).
    typeset -i _opp_inv_ok=0
    if [[ "${_OPP_POLICY_COUNT}" -gt 0 ]]; then
        _opp_inv_ok=1
    fi
    typeset -i _opp_failures=$(( (1 - _opp_inv_ok) + (1 - _opp_sel) ))
    _opp_junit="${ARTIFACT_DIR}/junit_grc_placement_restore.xml"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"grc-placement-restore\" tests=\"2\" failures=\"${_opp_failures}\">"
        echo "  <testcase classname=\"grc-placement-restore\" name=\"operatorpolicy-inventory-nonempty\">"
        if [[ "${_opp_inv_ok}" -ne 1 ]]; then
            echo "    <failure message=\"$(_opp_xesc "operatorpolicy inventory at pre-GRC capture: ${_OPP_POLICY_COUNT} objects")\"></failure>"
        fi
        echo "  </testcase>"
        echo "  <testcase classname=\"grc-placement-restore\" name=\"placement-selects-local-cluster\">"
        if [[ "${_opp_sel}" -ne 1 ]]; then
            echo "    <failure message=\"$(_opp_xesc "placement ${_OPP_PLACEMENT_NAME} does not select ${_OPP_MC_NAME} after the GRC suite; see 04-label-restore.log and 05-placement-status-post.json in this step artifacts")\"></failure>"
        fi
        echo "  </testcase>"
        echo "</testsuite>"
    } > "${_opp_junit}"
    if [[ "${_opp_failures}" -gt 0 ]]; then
        echo "OPP placement checks FAILED; see ${_opp_junit}" >&2
        if [[ "${_test_rc}" -eq 0 ]]; then
            _test_rc=1
        fi
    fi
fi

exit "${_test_rc}"
