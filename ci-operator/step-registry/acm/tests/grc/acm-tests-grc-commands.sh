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
        # Restore one canonical carrier after ExitTrap archives the original
        # (INTEROP-9666). The copy is written to a temporary file and renamed
        # into place, so a failed copy cannot leave truncated XML at the
        # canonical name; a failed restore fails the step (see the trap below).
        typeset -i _grc_restore_failed=0
        typeset -i _grc_exit_rc=0
        typeset -i _grc_helper_rc=0
        _grc_restore_carrier() {
            local _src="$1" _dst="$2" _tmp
            _tmp="${ARTIFACT_DIR}/.$(basename "${_dst}").restore.$$"
            if cp "${_src}" "${_tmp}" 2>&1 && mv "${_tmp}" "${_dst}" 2>&1; then
                return 0
            fi
            rm -f "${_tmp}"
            echo "ERROR: GRC carrier restore failed for ${_dst}" >&2
            _grc_restore_failed=1
            return 1
        }
        trap '
            _grc_exit_rc=$?
            # Guard the helper: if a published carrier has no confirmed
            # backup, the helper would archive the original with nothing to
            # restore. Skip the helper in that case and propagate failure.
            _grc_helper_rc=0
            _grc_skip_helper=0
            if [[ -f "${ARTIFACT_DIR}/junit_grc.xml" && ! -f "/tmp/junit_grc_backup.xml" ]]; then
                echo "WARNING: GRC carrier backup missing; skipping ExitTrap helper to preserve ${ARTIFACT_DIR}/junit_grc.xml" >&2
                _grc_skip_helper=1
            fi
            if [[ -f "${ARTIFACT_DIR}/junit_grc_placement_restore.xml" && ! -f "/tmp/junit_grc_placement_restore_backup.xml" ]]; then
                echo "WARNING: placement restore carrier backup missing; skipping ExitTrap helper to preserve ${ARTIFACT_DIR}/junit_grc_placement_restore.xml" >&2
                _grc_skip_helper=1
            fi
            if (( _grc_skip_helper == 0 )); then
                # Call the helper as a plain command, never on the left of `||`:
                # bash suppresses its own errexit in that position, so an internal
                # archive/remap/copy failure would return success.
                LP_IO__ET_PPP__NEW_TS_NAME="%s" \
                    ExitTrap--PostProcessPrep
                _grc_helper_rc=$?
            else
                _grc_helper_rc=1
                if (( _grc_exit_rc == 0 )); then
                    _grc_exit_rc=1
                fi
            fi
            if [[ -f "/tmp/junit_grc_backup.xml" ]]; then
                _grc_restore_carrier "/tmp/junit_grc_backup.xml" "${ARTIFACT_DIR}/junit_grc.xml"
            fi
            if [[ -f "/tmp/junit_grc_placement_restore_backup.xml" ]]; then
                _grc_restore_carrier "/tmp/junit_grc_placement_restore_backup.xml" "${ARTIFACT_DIR}/junit_grc_placement_restore.xml"
            fi
            if (( (_grc_restore_failed || _grc_helper_rc != 0) )) && (( _grc_exit_rc == 0 )); then
                _grc_exit_rc=1
            fi
            exit "${_grc_exit_rc}"
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

# Temp allocation, checked (errexit is disabled). mktemp can fail on a full or
# unwritable /tmp, and an empty result would turn later redirects and globs
# into paths under "/", so every allocation goes through these helpers.
typeset -i _tmp_alloc_failed=0
# Usage: _mk_tmp VARNAME | _mk_tmpdir VARNAME (assigns VARNAME in the caller's
# scope). On failure VARNAME is empty and the reason goes to stderr; the step
# result is failed at exit instead of silently continuing with an empty path.
_mk_tmp() {
    local _name="$1" _t=""
    _t="$(mktemp 2>/dev/null)" || _t=""
    printf -v "${_name}" '%s' "${_t}"
    if [[ -z "${_t}" ]]; then
        echo "ERROR: mktemp file allocation failed for ${_name}" >&2
        _tmp_alloc_failed=1
        return 1
    fi
}
_mk_tmpdir() {
    local _name="$1" _t=""
    _t="$(mktemp -d 2>/dev/null)" || _t=""
    printf -v "${_name}" '%s' "${_t}"
    if [[ -z "${_t}" ]]; then
        echo "ERROR: mktemp directory allocation failed for ${_name}" >&2
        _tmp_alloc_failed=1
        return 1
    fi
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
typeset -i _OPP_QUERY_FAILED=0
typeset -i _OPP_POLICY_COUNT=-1
# Declared at script scope, not inside the snapshot block: the post-suite
# carrier reads it, so a declaration in the placement-present branch would
# leave it unbound (nounset) whenever that branch is not taken.
typeset -i _OPP_BASELINE_OK=0
# Three-way placement probe. The previous `>/dev/null 2>&1` form collapsed
# every failure into "this lane has no OPP placement": an API error, an RBAC
# gap or a timeout then skipped the whole post-suite block, so the
# relabel/detach regression INTEROP-9711 targets went unobserved on a green
# step with no grc-placement-restore carrier row. The error text separates
# the three states. A missing object or namespace, or a cluster without the
# placements API, means this lane has no OPP placement (inactive, as before,
# which keeps the non-OPP consumers of this step green). Any other failure is
# an undetermined answer: it must surface as a failed check, not as silence.
_OPP_QUERY_LOG=""
_mk_tmp _OPP_QUERY_LOG
typeset -i _OPP_QUERY_RC=0
oc get placement "-n${_OPP_PLACEMENT_NS}" "${_OPP_PLACEMENT_NAME}" >/dev/null 2>"${_OPP_QUERY_LOG}" || _OPP_QUERY_RC=$?
# The label baseline is the only source the post-suite restore can mutate from,
# and the suite runs whatever the probe answered, so it is captured first and
# independently of the raw staging directory. It lives outside ARTIFACT_DIR and
# is never published; only its scrubbed copy in the snapshot set is.
_opp_baseline_private="/tmp/opp_labels_baseline_private.json"
_opp_baseline_tmp=""
_mk_tmp _opp_baseline_tmp
if [[ -n "${_opp_baseline_tmp}" ]] && \
    oc get managedcluster "${_OPP_MC_NAME}" -o json 2>/dev/null | \
    python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({
    "name": d["metadata"]["name"],
    "labels": d["metadata"].get("labels", {})
}, indent=2))
' > "${_opp_baseline_tmp}" && \
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    raise SystemExit(0 if isinstance(d.get("labels"), dict) else 1)
except Exception:
    raise SystemExit(1)
' "${_opp_baseline_tmp}" && mv "${_opp_baseline_tmp}" "${_opp_baseline_private}"; then
    _OPP_BASELINE_OK=1
else
    rm -f "${_opp_baseline_tmp}" "${_opp_baseline_private}"
    echo "ERROR: OPP label baseline unreadable; the suite still runs, the post-suite restore is skipped and reported as a failure" >&2
fi
# The raw snapshots are staged outside ARTIFACT_DIR; without a staging
# directory they must not be collected at all (an empty staging path would
# redirect them to /).
typeset -i _OPP_SNAPSHOT_FAILED=0
_OPP_RAW_STAGING=""
if (( _OPP_QUERY_RC == 0 )); then
    _mk_tmpdir _OPP_RAW_STAGING
fi
if (( _OPP_QUERY_RC == 0 )) && [[ -z "${_OPP_RAW_STAGING}" ]]; then
    _OPP_ACTIVE=1
    mkdir -p "${_OPP_EVIDENCE_DIR}"
    echo "ERROR: cannot allocate the OPP evidence staging directory; snapshot collection skipped" >&2
    echo "=== OPP snapshot skipped: staging allocation failed $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" > "${_OPP_EVIDENCE_DIR}/00-snapshot-skipped.log"
    _OPP_SNAPSHOT_FAILED=1
elif (( _OPP_QUERY_RC == 0 )); then
    _OPP_ACTIVE=1
    mkdir -p "${_OPP_RAW_STAGING}" "${_OPP_EVIDENCE_DIR}"
    # A capture that failed must never be published: the parser traceback would
    # otherwise be scrubbed and moved into the artifacts as if it were JSON.
    typeset -i _opp_cap_rc=0
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
' > "${_OPP_RAW_STAGING}/01-operatorpolicy.json" 2>&1 || _opp_cap_rc=$?
    if (( _opp_cap_rc != 0 )); then
        rm -f "${_OPP_RAW_STAGING}/01-operatorpolicy.json"
        echo "ERROR: OPP OperatorPolicy inventory capture failed (rc=${_opp_cap_rc}); not published" >&2
        _OPP_SNAPSHOT_FAILED=1
    fi
    _OPP_POLICY_COUNT="$(python3 -c '
import json, sys
try:
    print(len(json.load(open(sys.argv[1]))))
except Exception:
    print(-1)
' "${_OPP_RAW_STAGING}/01-operatorpolicy.json")"
    if ! echo "${_OPP_POLICY_COUNT}" > "${_OPP_RAW_STAGING}/00-operatorpolicy-count.txt"; then
        echo "ERROR: failed to write OperatorPolicy count artifact" >&2
        _OPP_SNAPSHOT_FAILED=1
    fi
    # 2. local-cluster labels: the same baseline the restore uses, copied from
    #    the private capture so the published snapshot cannot diverge from the
    #    restore source.
    if [[ -f "${_opp_baseline_private}" ]]; then
        if ! cp "${_opp_baseline_private}" "${_OPP_RAW_STAGING}/02-managedcluster-labels.json"; then
            rm -f "${_OPP_RAW_STAGING}/02-managedcluster-labels.json"
            echo "ERROR: failed to stage the label baseline snapshot; not published" >&2
            _OPP_SNAPSHOT_FAILED=1
        fi
    fi
    # 3. Placement status (pre-suite state) and the authoritative
    #    PlacementDecision resources (the placement controller writes
    #    selected cluster names there, not into Placement.status).
    _opp_cap_rc=0
    oc get placement "-n${_OPP_PLACEMENT_NS}" "${_OPP_PLACEMENT_NAME}" -o json 2>/dev/null | \
        python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({
    "name": d["metadata"]["name"],
    "namespace": d["metadata"]["namespace"],
    "status": d.get("status", {})
}, indent=2))
' > "${_OPP_RAW_STAGING}/03-placement-status.json" 2>&1 || _opp_cap_rc=$?
    if (( _opp_cap_rc != 0 )); then
        rm -f "${_OPP_RAW_STAGING}/03-placement-status.json"
        echo "ERROR: OPP placement status capture failed (rc=${_opp_cap_rc}); not published" >&2
        _OPP_SNAPSHOT_FAILED=1
    fi
    _opp_cap_rc=0
    oc get placementdecision "-n${_OPP_PLACEMENT_NS}" -l "cluster.open-cluster-management.io/placement=${_OPP_PLACEMENT_NAME}" -o json 2>/dev/null | \
        python3 -c '
import json, sys
d = json.load(sys.stdin)
result = []
for item in d.get("items", []):
    result.append({
        "name": item["metadata"]["name"],
        "decisions": item.get("status", {}).get("decisions")
    })
print(json.dumps(result, indent=2))
' > "${_OPP_RAW_STAGING}/03-placementdecisions.json" 2>&1 || _opp_cap_rc=$?
    if (( _opp_cap_rc != 0 )); then
        rm -f "${_OPP_RAW_STAGING}/03-placementdecisions.json"
        echo "ERROR: OPP placementdecision capture failed (rc=${_opp_cap_rc}); not published" >&2
        _OPP_SNAPSHOT_FAILED=1
    fi
    # Scrub the snapshot files (both passes) before they land in artifacts.
    # Raw snapshots are in staging outside ARTIFACT_DIR; publish only after scrub succeeds.
    # Tracing is already off in this section; keep it off for the suite run.
    for _opp_f in "${_OPP_RAW_STAGING}"/*.json "${_OPP_RAW_STAGING}"/*.txt; do
        [[ -f "${_opp_f}" ]] || continue
        _opp_tmp=""
        _mk_tmp _opp_tmp
        _opp_dest="${_OPP_EVIDENCE_DIR}/$(basename "${_opp_f}")"
        typeset -i _opp_scrub_ok=1
        if [[ -n "${_secrets_pattern}" ]]; then
            if ! sed -E "s/${_secrets_pattern}/[REDACTED]/g" "${_opp_f}" > "${_opp_tmp}"; then
                echo "ERROR: OPP evidence value scrub failed for ${_opp_f}" >&2
                _opp_scrub_ok=0
                rm -f "${_opp_tmp}"
            fi
        else
            if ! cp "${_opp_f}" "${_opp_tmp}"; then
                echo "ERROR: OPP evidence staging copy failed for ${_opp_f}" >&2
                _opp_scrub_ok=0
                rm -f "${_opp_tmp}"
            fi
        fi
        if (( _opp_scrub_ok )); then
            if ! _scrub_leaktk_patterns -i "${_opp_tmp}"; then
                echo "ERROR: OPP evidence pattern scrub failed for ${_opp_f}" >&2
                _opp_scrub_ok=0
                rm -f "${_opp_tmp}"
            fi
        fi
        if (( _opp_scrub_ok )); then
            if ! mv "${_opp_tmp}" "${_opp_dest}"; then
                echo "ERROR: OPP evidence publish failed for ${_opp_dest}" >&2
                _opp_scrub_ok=0
            fi
        fi
        # Missing evidence is a failed check, not a warning: the step must not
        # report success with an incomplete snapshot set.
        if (( _opp_scrub_ok )); then
            :
        else
            rm -f "${_opp_tmp}" "${_opp_dest}"
            echo "WARNING: ${_opp_f} was not published to ${_opp_dest}" >&2
            _OPP_SNAPSHOT_FAILED=1
        fi
    done
    rm -rf "${_OPP_RAW_STAGING}"
    echo "OPP snapshot taken: ${_OPP_POLICY_COUNT} OperatorPolicy objects; labels and placement state in ${_OPP_EVIDENCE_DIR}"
else
    # The probe above did not answer yes or no. Treat the lane as OPP-shaped
    # only if the error is not one of the "no such placement here" shapes.
    if grep -qiE 'not[[:space:]]*found|doesn.t have a resource type|no matches for kind|could not find the requested resource' "${_OPP_QUERY_LOG}"; then
        echo "No OPP placement in ${_OPP_PLACEMENT_NS} (oc get placement rc=${_OPP_QUERY_RC}); OPP checks inactive for this lane"
    else
        _OPP_QUERY_FAILED=1
        mkdir -p "${_OPP_EVIDENCE_DIR}"
        _opp_query_raw=""
        _mk_tmp _opp_query_raw
        if [[ -n "${_opp_query_raw}" ]]; then
            {
                echo "oc get placement -n${_OPP_PLACEMENT_NS} ${_OPP_PLACEMENT_NAME} failed with rc=${_OPP_QUERY_RC}"
                sed 's/^/  /' "${_OPP_QUERY_LOG}"
            } > "${_opp_query_raw}" 2>&1 || true
            _opp_query_tmp=""
            _mk_tmp _opp_query_tmp
            _opp_query_dest="${_OPP_EVIDENCE_DIR}/00-placement-query-error.log"
            typeset -i _opp_query_scrub_ok=1
            if [[ -n "${_secrets_pattern}" ]]; then
                if ! sed -E "s/${_secrets_pattern}/[REDACTED]/g" "${_opp_query_raw}" > "${_opp_query_tmp}"; then
                    echo "ERROR: OPP placement query error value scrub failed" >&2
                    _opp_query_scrub_ok=0
                    rm -f "${_opp_query_tmp}"
                fi
            else
                if ! cp "${_opp_query_raw}" "${_opp_query_tmp}"; then
                    echo "ERROR: OPP placement query error staging copy failed" >&2
                    _opp_query_scrub_ok=0
                    rm -f "${_opp_query_tmp}"
                fi
            fi
            if (( _opp_query_scrub_ok )); then
                if ! _scrub_leaktk_patterns -i "${_opp_query_tmp}"; then
                    echo "ERROR: OPP placement query error pattern scrub failed" >&2
                    _opp_query_scrub_ok=0
                    rm -f "${_opp_query_tmp}"
                fi
            fi
            if (( _opp_query_scrub_ok )); then
                if ! mv "${_opp_query_tmp}" "${_opp_query_dest}"; then
                    echo "ERROR: OPP placement query error publish failed for ${_opp_query_dest}" >&2
                    _opp_query_scrub_ok=0
                fi
            fi
            if (( _opp_query_scrub_ok )); then
                :
            else
                rm -f "${_opp_query_tmp}" "${_opp_query_dest}"
                echo "WARNING: ${_opp_query_raw} was not published to ${_opp_query_dest}" >&2
                _OPP_SNAPSHOT_FAILED=1
            fi
            rm -f "${_opp_query_raw}"
        else
            echo "ERROR: cannot allocate temp for OPP placement query error" >&2
            _OPP_SNAPSHOT_FAILED=1
        fi
        echo "ERROR: OPP placement query failed (rc=${_OPP_QUERY_RC}); a failed query is not a lane without OPP, so the OPP checks will run and report this as a failure. See co-located 00-placement-query-error.log" >&2
    fi
fi
rm -f "${_OPP_QUERY_LOG}"

# Run the test suite with all output captured to a temp file.
_grc_raw_log=""
_mk_tmp _grc_raw_log
typeset -i _test_rc=0
./execute_grc_interop_commands.sh > "${_grc_raw_log}" 2>&1 || _test_rc=$?

# --- Pass 1: VALUE-BASED scrub (known secret literals) --------------------
_grc_scrubbed_log=""
_mk_tmp _grc_scrubbed_log
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
_grc_pattern_scrubbed=""
_mk_tmp _grc_pattern_scrubbed
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

# --- GRC JUnit carrier (INTEROP-9666) --------------------------------------
# Flatten Cypress outputs into a single lowercase carrier with the canonical
# suite name. Derive the canonical filename at write time (MPEX L24):
# ${ARTIFACT_DIR}/junit_grc.xml with suite lp-interop--ACM--OPP--grc.
# Collect every JUnit XML under test-output (both cypress/ and any
# out-of-tree reporter), merge their <testcase> elements, and write once.
# This removes the hash-shaped per-spec publish (junit_cypress-<hash>.xml)
# and the capital-U jUnit.xml that the prow lens never discovers.
set +x  # sed patterns reference escaped secret values
_grc_canonical_junit="${ARTIFACT_DIR}/junit_grc.xml"
_grc_staging_unscrubbed=""
_mk_tmp _grc_staging_unscrubbed
_grc_staging_scrubbed=""
_mk_tmp _grc_staging_scrubbed
typeset -i _grc_py_rc=0
_GRC_STAGING_UNSCRUBBED="${_grc_staging_unscrubbed}" python3 <<'PYEOF_GRC' 2>&1 | sed 's/^/[grc-junit] /' || _grc_py_rc=$?
import os, sys, pathlib, xml.etree.ElementTree as ET
staging = os.environ.get("_GRC_STAGING_UNSCRUBBED", "/tmp/grc_staging_unscrubbed.xml")
test_output_root = pathlib.Path("test-output")
xml_files = []
if test_output_root.is_dir():
    for p in test_output_root.rglob("*.xml"):
        if p.is_file():
            xml_files.append(str(p))
testcases = []
suite_time = 0.0
carrier_failures = []
for xf in xml_files:
    try:
        tree = ET.parse(xf)
        root = tree.getroot()
        for tc in root.iter("testcase"):
            if "classname" not in tc.attrib or not tc.attrib["classname"]:
                tc.set("classname", "acm-tests-grc")
            try:
                suite_time += float(tc.get("time", "0") or 0)
            except Exception:
                pass
            testcases.append(tc)
    except ET.ParseError as e:
        print(f"WARNING: failed to parse {xf}: {e}", file=sys.stderr)
        tc = ET.Element("testcase", {"classname": "acm-tests-grc", "name": f"JUnit parse failure: {xf}", "time": "0"})
        fail = ET.SubElement(tc, "failure", {"message": f"parse failure for {xf}"})
        fail.text = str(e)
        testcases.append(tc)
        carrier_failures.append(xf)
        continue
    except Exception as e:
        print(f"WARNING: failed to read {xf}: {e}", file=sys.stderr)
        tc = ET.Element("testcase", {"classname": "acm-tests-grc", "name": f"JUnit read failure: {xf}", "time": "0"})
        fail = ET.SubElement(tc, "failure", {"message": f"read failure for {xf}"})
        fail.text = str(e)
        testcases.append(tc)
        carrier_failures.append(xf)
        continue
synthetic = False
if not testcases:
    synthetic = True
    tc = ET.Element("testcase", {"classname": "acm-tests-grc", "name": "GRC Cypress JUnit not found", "time": "0"})
    fail = ET.SubElement(tc, "failure", {"message": "no Cypress JUnit XML found under test-output"})
    fail.text = "no JUnit XML discovered under test-output; expected Cypress reporter output"
    testcases.append(tc)
tests = len(testcases)
failures = sum(1 for tc in testcases if tc.find("failure") is not None)
errors = sum(1 for tc in testcases if tc.find("error") is not None)
skipped = sum(1 for tc in testcases if tc.find("skipped") is not None)
suite = ET.Element("testsuite", {
    "name": "lp-interop--ACM--OPP--grc",
    "tests": str(tests),
    "failures": str(failures),
    "errors": str(errors),
    "skipped": str(skipped),
    "time": str(suite_time)
})
for tc in testcases:
    suite.append(tc)
tree_out = ET.ElementTree(suite)
try:
    tree_out.write(staging, encoding="utf-8", xml_declaration=True)
    print(f"wrote {staging} with {tests} testcases (failures={failures}) from {len(xml_files)} source files synthetic={synthetic}")
    if synthetic:
        pathlib.Path("/tmp/grc_synthetic_needed").touch()
    if carrier_failures:
        print(f"{len(carrier_failures)} source report(s) unreadable; failure rows emitted", file=sys.stderr)
        pathlib.Path("/tmp/grc_parse_failures").touch()
except Exception as e:
    print(f"failed to write {staging}: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF_GRC
if (( _grc_py_rc != 0 )); then
    echo "ERROR: GRC JUnit generator failed rc=${_grc_py_rc}" >&2
    if [[ "${_test_rc}" -eq 0 ]]; then
        _test_rc=1
    fi
fi
# Stage outside ARTIFACT_DIR, publish only after scrub succeeds (and generator succeeded)
typeset -i _grc_scrub_ok=1
if (( _grc_py_rc == 0 )) && [[ -f "${_grc_staging_unscrubbed}" ]]; then
    if [[ -n "${_secrets_pattern}" ]]; then
        # XML-aware value scrub: redact only text and attribute values, not tag names
        if ! _GRC_SECRETS_PATTERN="${_secrets_pattern}" _GRC_STAGING_UNSCRUBBED="${_grc_staging_unscrubbed}" _GRC_STAGING_SCRUBBED="${_grc_staging_scrubbed}" python3 <<'PYEOF_SCRUB' 2>&1 | sed 's/^/[grc-scrub] /'; then
import os, re, pathlib, xml.etree.ElementTree as ET
pat = os.environ.get("_GRC_SECRETS_PATTERN", "")
src = os.environ.get("_GRC_STAGING_UNSCRUBBED", "")
dst = os.environ.get("_GRC_STAGING_SCRUBBED", "")
if not pat:
    raise SystemExit(0)
try:
    rx = re.compile(pat)
except re.error as e:
    print(f"secret pattern compile failed: {e}", file=sys.stderr)
    raise SystemExit(1)
try:
    tree = ET.parse(src)
    root = tree.getroot()
    for el in root.iter():
        for k in list(el.attrib.keys()):
            v = el.attrib[k]
            nv = rx.sub("[REDACTED]", v)
            if nv != v:
                el.set(k, nv)
        if el.text:
            el.text = rx.sub("[REDACTED]", el.text)
        if el.tail:
            el.tail = rx.sub("[REDACTED]", el.tail)
    tree.write(dst, encoding="utf-8", xml_declaration=True)
except Exception as e:
    print(f"value scrub failed: {e}", file=sys.stderr)
    raise SystemExit(1)
PYEOF_SCRUB
            echo "ERROR: GRC value-based scrub failed for ${_grc_staging_unscrubbed}" >&2
            _grc_scrub_ok=0
            if [[ "${_test_rc}" -eq 0 ]]; then
                _test_rc=1
            fi
        fi
    else
        if ! cp "${_grc_staging_unscrubbed}" "${_grc_staging_scrubbed}"; then
            echo "ERROR: GRC staging copy failed for ${_grc_staging_unscrubbed}" >&2
            _grc_scrub_ok=0
            if [[ "${_test_rc}" -eq 0 ]]; then
                _test_rc=1
            fi
        fi
    fi
    if (( _grc_scrub_ok )); then
        if ! _GRC_STAGING_SCRUBBED="${_grc_staging_scrubbed}" python3 <<'PYEOF_LEAKTK' 2>&1 | sed 's/^/[grc-scrub-pattern] /'; then
import os, re, xml.etree.ElementTree as ET
src = os.environ.get("_GRC_STAGING_SCRUBBED", "")
# leaktk patterns applied to parsed XML values only, never to serialized
# markup (the markup must stay parseable for prow). The rule set mirrors
# _scrub_leaktk_patterns above; keep the two in step. Each rule carries its own
# replacement, so no dispatch keyed on pattern text is needed; the bracket
# tricks keep the patterns from matching themselves when ci-operator embeds
# this script in pods.json.
rules = [
    (r'(Authorizatio[n]:[ \t]*([Bb]earer[ \t]+)?)[A-Za-z0-9._~+/=-]{16,}', r'\1[REDACTED]', 0),
    (r'(([Bb]eare[r][ \t]+))[A-Za-z0-9._~+/=-]{16,}', r'\1[REDACTED]', 0),
    (r'(toke[n]=[ \t]*)([A-Za-z0-9._~+/=-]{16,})', r'\1[REDACTED]', 0),
    (r'-----BEGI[N] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)-----', '[REDACTED:PEM-HEADER]', 0),
    (r'-----EN[D] (CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|PUBLIC KEY)-----', '[REDACTED:PEM-FOOTER]', 0),
    (r'("[A-Za-z0-9_-]*(passwo[r]d|secre[t]|toke[n]|beare[r]|credentia[l])(_?(key|code))?[ \t]*"[ \t]*:[ \t]*")([^"\\]|\\.)+', r'\1[REDACTED]', re.IGNORECASE),
]
compiled = []
for pat, repl, flags in rules:
    try:
        compiled.append((re.compile(pat, flags), repl))
    except re.error as e:
        print(f"pattern compile failed {pat}: {e}")
        raise SystemExit(1)
def scrub_value(value):
    for rx, repl in compiled:
        value = rx.sub(repl, value)
    return value
try:
    tree = ET.parse(src)
    root = tree.getroot()
    for el in root.iter():
        for k in list(el.attrib.keys()):
            nv = scrub_value(el.attrib[k])
            if nv != el.attrib[k]:
                el.set(k, nv)
        if el.text:
            el.text = scrub_value(el.text)
        if el.tail:
            el.tail = scrub_value(el.tail)
    tree.write(src, encoding="utf-8", xml_declaration=True)
except Exception as e:
    print(f"leaktk pattern scrub failed: {e}")
    raise SystemExit(1)
PYEOF_LEAKTK
            echo "ERROR: GRC pattern scrub failed for ${_grc_staging_scrubbed}" >&2
            _grc_scrub_ok=0
            if [[ "${_test_rc}" -eq 0 ]]; then
                _test_rc=1
            fi
        fi
        # Validate final carrier is well-formed XML before publishing
        if (( _grc_scrub_ok )); then
            if ! python3 -c 'import xml.etree.ElementTree as ET, sys; ET.parse(sys.argv[1])' "${_grc_staging_scrubbed}" 2>&1; then
                echo "ERROR: GRC carrier XML validation failed for ${_grc_staging_scrubbed}" >&2
                _grc_scrub_ok=0
                if [[ "${_test_rc}" -eq 0 ]]; then
                    _test_rc=1
                fi
            fi
        fi
    fi
    if (( _grc_scrub_ok )); then
        if ! mv "${_grc_staging_scrubbed}" "${_grc_canonical_junit}"; then
            echo "ERROR: GRC JUnit publish failed for ${_grc_canonical_junit}" >&2
            rm -f "${_grc_staging_scrubbed}"
            if [[ "${_test_rc}" -eq 0 ]]; then
                _test_rc=1
            fi
        else
            # Backup atomically: a partial copy must never leave a truncated
            # file at the path the EXIT trap restores from.
            _grc_backup_tmp=""
            if ! _grc_backup_tmp="$(mktemp /tmp/junit_grc_backup.XXXXXX 2>/dev/null)" ||
                ! cp "${_grc_canonical_junit}" "${_grc_backup_tmp}" ||
                ! mv "${_grc_backup_tmp}" "/tmp/junit_grc_backup.xml"; then
                echo "ERROR: GRC JUnit backup failed for ${_grc_canonical_junit}" >&2
                rm -f "${_grc_backup_tmp:-}"
                if [[ "${_test_rc}" -eq 0 ]]; then
                    _test_rc=1
                fi
            fi
        fi
        if [[ -f "/tmp/grc_synthetic_needed" ]]; then
            rm -f "/tmp/grc_synthetic_needed"
            if [[ "${_test_rc}" -eq 0 ]]; then
                _test_rc=1
            fi
            echo "GRC JUnit synthetic failure emitted; marking _test_rc=1" >&2
        fi
    else
        echo "ERROR: GRC JUnit scrub failed; not publishing unscrubbed carrier" >&2
        rm -f "${_grc_staging_scrubbed}" "${_grc_staging_unscrubbed}"
        if [[ "${_test_rc}" -eq 0 ]]; then
            _test_rc=1
        fi
    fi
    if [[ -f "/tmp/grc_parse_failures" ]]; then
        rm -f "/tmp/grc_parse_failures"
        if [[ "${_test_rc}" -eq 0 ]]; then
            _test_rc=1
        fi
        echo "GRC JUnit parse/read failure rows emitted; marking _test_rc=1" >&2
    fi
    rm -f "${_grc_staging_unscrubbed}"
else
    if (( _grc_py_rc != 0 )); then
        echo "ERROR: GRC JUnit generator failed rc=${_grc_py_rc}; not publishing carrier" >&2
    else
        echo "ERROR: GRC canonical staging not created at ${_grc_staging_unscrubbed}" >&2
    fi
    if [[ "${_test_rc}" -eq 0 ]]; then
        _test_rc=1
    fi
    rm -f "${_grc_staging_scrubbed}"
fi
set -x

# --- OPP placement restore and assert (INTEROP-9711) ----------------------
# Restore the local-cluster labels the GRC suite may have changed (the
# exclusive clusterset label was moved to global mid-suite), wait for the
# OPP placement to re-select local-cluster, and record both checks as JUnit
# rows so prow and the run gates see the outcome. The emitted suite name is
# short; on lanes with MAP_TESTS=true the ExitTrap merge prefixes it with
# the Component Readiness prefix for this step.
if [[ "${_OPP_ACTIVE}" -eq 1 || "${_OPP_QUERY_FAILED}" -eq 1 ]]; then
    _opp_xesc() {
        printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
    }
    # Restore drifted OPP-relevant labels from the pre-suite snapshot.
    # Only a validated baseline may drive label mutations: an unreadable
    # baseline skips the restore entirely and is reported as a failure.
    if [[ "${_OPP_BASELINE_OK}" -ne 1 ]]; then
        echo "=== OPP label restore skipped: baseline snapshot unreadable $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" > "${_OPP_EVIDENCE_DIR}/04-label-restore.log"
    else
        set +x
        if [[ ! -f "${_opp_baseline_private}" ]]; then
            echo "ERROR: private baseline missing; skipping restore" >&2
            echo "=== OPP label restore skipped: private baseline missing $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" > "${_OPP_EVIDENCE_DIR}/04-label-restore.log"
            _OPP_BASELINE_OK=0
        elif ! python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    raise SystemExit(0 if isinstance(d.get("labels"), dict) else 1)
except Exception:
    raise SystemExit(1)
' "${_opp_baseline_private}"; then
            echo "ERROR: private baseline invalid; skipping restore" >&2
            echo "=== OPP label restore skipped: private baseline invalid $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" > "${_OPP_EVIDENCE_DIR}/04-label-restore.log"
            _OPP_BASELINE_OK=0
        else
        {
            echo "=== OPP label restore $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
            for _opp_key in "${_OPP_LABEL_KEYS[@]}"; do
                _opp_pre="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    labels = d.get("labels", {})
    if sys.argv[2] not in labels:
        print("<absent>")
    else:
        v = labels.get(sys.argv[2])
        print(v if v is not None else "")
except Exception:
    print("__OPP_READ_ERROR__")
    raise SystemExit(1)
' "${_opp_baseline_private}" "${_opp_key}" 2>/dev/null)" || _opp_pre="__OPP_READ_ERROR__"
                if [[ "${_opp_pre}" == "__OPP_READ_ERROR__" ]]; then
                    echo "ERROR: baseline read failed for ${_opp_key}; skipping mutation" >&2
                    echo "baseline read error for ${_opp_key}" >&2
                    continue
                fi
                _opp_cur="__OPP_READ_ERROR__"
                for _opp_rtry in 1 2 3; do
                    if _opp_cur="$(oc get managedcluster "${_OPP_MC_NAME}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    labels = d["metadata"].get("labels", {})
    if sys.argv[1] not in labels:
        print("<absent>")
    else:
        v = labels.get(sys.argv[1])
        print(v if v is not None else "")
except Exception:
    print("__OPP_READ_ERROR__")
    raise SystemExit(1)
' "${_opp_key}" 2>/dev/null)" && [[ "${_opp_cur}" != "__OPP_READ_ERROR__" ]]; then
                        break
                    fi
                    # A failed read leaves the substitution empty; reset to the
                    # sentinel so an empty live value is never read as restored.
                    _opp_cur="__OPP_READ_ERROR__"
                    sleep 2
                done
                if [[ "${_opp_cur}" == "__OPP_READ_ERROR__" ]]; then
                    echo "ERROR: failed to read current label ${_opp_key} after retry; skipping" >&2
                    echo "current read error for ${_opp_key}" >&2
                    continue
                fi
                if [[ "${_opp_pre}" != "${_opp_cur}" ]]; then
                    echo "restoring label ${_opp_key}: drift detected"
                    if [[ "${_opp_pre}" == "<absent>" ]]; then
                        if [[ "${_opp_cur}" != "<absent>" ]]; then
                            typeset -i _opp_label_rc=0
                            for _opp_try_label in 1 2 3; do
                                oc label managedclusters "${_OPP_MC_NAME}" "${_opp_key}-" --overwrite 2>&1 && break
                                _opp_label_rc=$?
                                sleep 2
                            done
                            (( _opp_label_rc == 0 )) || echo "WARNING: failed to delete label ${_opp_key} after 3 attempts" >&2
                        fi
                    else
                        typeset -i _opp_label_rc=0
                        for _opp_try_label in 1 2 3; do
                            if [[ -z "${_opp_pre}" ]]; then
                                oc label managedclusters "${_OPP_MC_NAME}" "${_opp_key}=" --overwrite 2>&1 && break
                            else
                                oc label managedclusters "${_OPP_MC_NAME}" "${_opp_key}=${_opp_pre}" --overwrite 2>&1 && break
                            fi
                            _opp_label_rc=$?
                            sleep 2
                        done
                        (( _opp_label_rc == 0 )) || echo "WARNING: failed to restore label ${_opp_key} after 3 attempts" >&2
                    fi
                fi
            done
        } > "${_OPP_EVIDENCE_DIR}/04-label-restore.log" 2>&1
        fi
        set -x
    fi
    # Verify label restoration independently of placement: single
    # ManagedCluster read compared against all tracked keys (7534), with
    # bounded retry of read-compare-write so an API recovery can repair a
    # mismatch left by a failed restore read (7530). Failed reads stay
    # distinct from absent labels and never trigger deletion.
    typeset -i _opp_restore_ok=1
    if [[ "${_OPP_BASELINE_OK}" -eq 1 ]]; then
        set +x
        _opp_verify_json=""
        _mk_tmp _opp_verify_json
        typeset -i _opp_verify_fetch_ok=0
        for _opp_vrtry in 1 2 3; do
            if oc get managedcluster "${_OPP_MC_NAME}" -o json >"${_opp_verify_json}" 2>/dev/null && \
                python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get("metadata",{}).get("labels",{}), dict)' "${_opp_verify_json}" 2>/dev/null; then
                _opp_verify_fetch_ok=1
                break
            fi
            sleep 2
        done
        if (( _opp_verify_fetch_ok == 0 )); then
            echo "ERROR: verification read failed for ManagedCluster ${_OPP_MC_NAME} after retry" >&2
            echo "verification current read error (bulk fetch)" >> "${_OPP_EVIDENCE_DIR}/04-label-restore.log" 2>&1 || true
            _opp_restore_ok=0
            rm -f "${_opp_verify_json}"
        else
            for _opp_key in "${_OPP_LABEL_KEYS[@]}"; do
                _opp_verify_pre="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    labels = d.get("labels", {})
    if sys.argv[2] not in labels:
        print("<absent>")
    else:
        v = labels.get(sys.argv[2])
        print(v if v is not None else "")
except Exception:
    print("__OPP_READ_ERROR__")
    raise SystemExit(1)
' "${_opp_baseline_private}" "${_opp_key}" 2>/dev/null)" || _opp_verify_pre="__OPP_READ_ERROR__"
                if [[ "${_opp_verify_pre}" == "__OPP_READ_ERROR__" ]]; then
                    echo "ERROR: baseline verification read failed for ${_opp_key}" >&2
                    echo "verification baseline read error for ${_opp_key}" >> "${_OPP_EVIDENCE_DIR}/04-label-restore.log" 2>&1 || true
                    _opp_restore_ok=0
                    continue
                fi
                _opp_verify_cur="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    labels = d["metadata"].get("labels", {})
    if sys.argv[2] not in labels:
        print("<absent>")
    else:
        v = labels.get(sys.argv[2])
        print(v if v is not None else "")
except Exception:
    print("__OPP_READ_ERROR__")
    raise SystemExit(1)
' "${_opp_verify_json}" "${_opp_key}" 2>/dev/null)" || _opp_verify_cur="__OPP_READ_ERROR__"
                if [[ "${_opp_verify_cur}" == "__OPP_READ_ERROR__" ]]; then
                    echo "ERROR: verification parse failed for ${_opp_key}" >&2
                    echo "verification parse error for ${_opp_key}" >> "${_OPP_EVIDENCE_DIR}/04-label-restore.log" 2>&1 || true
                    _opp_restore_ok=0
                    continue
                fi
                if [[ "${_opp_verify_pre}" != "${_opp_verify_cur}" ]]; then
                    echo "verification mismatch for ${_opp_key}: attempting repair" >&2
                    for _opp_vrtry in 1 2 3; do
                        _opp_verify_retry_json=""
                        _mk_tmp _opp_verify_retry_json
                        typeset -i _opp_verify_retry_ok=0
                        if oc get managedcluster "${_OPP_MC_NAME}" -o json >"${_opp_verify_retry_json}" 2>/dev/null && \
                            python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get("metadata",{}).get("labels",{}), dict)' "${_opp_verify_retry_json}" 2>/dev/null; then
                            _opp_verify_retry_ok=1
                            _opp_verify_retry_cur="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    labels = d["metadata"].get("labels", {})
    if sys.argv[2] not in labels:
        print("<absent>")
    else:
        v = labels.get(sys.argv[2])
        print(v if v is not None else "")
except Exception:
    print("__OPP_READ_ERROR__")
    raise SystemExit(1)
' "${_opp_verify_retry_json}" "${_opp_key}" 2>/dev/null)" || _opp_verify_retry_cur="__OPP_READ_ERROR__"
                            if [[ "${_opp_verify_retry_cur}" == "__OPP_READ_ERROR__" ]]; then
                                _opp_verify_retry_ok=0
                            elif [[ "${_opp_verify_pre}" != "${_opp_verify_retry_cur}" ]]; then
                                if [[ "${_opp_verify_pre}" == "<absent>" ]]; then
                                    if [[ "${_opp_verify_retry_cur}" != "<absent>" ]]; then
                                        oc label managedclusters "${_OPP_MC_NAME}" "${_opp_key}-" --overwrite 2>&1 || true
                                    fi
                                else
                                    if [[ -z "${_opp_verify_pre}" ]]; then
                                        oc label managedclusters "${_OPP_MC_NAME}" "${_opp_key}=" --overwrite 2>&1 || true
                                    else
                                        oc label managedclusters "${_OPP_MC_NAME}" "${_opp_key}=${_opp_verify_pre}" --overwrite 2>&1 || true
                                    fi
                                fi
                                sleep 2
                            else
                                rm -f "${_opp_verify_retry_json}"
                                break
                            fi
                        fi
                        rm -f "${_opp_verify_retry_json}"
                        if (( _opp_verify_retry_ok == 0 )); then
                            sleep 2
                        fi
                    done
                    _opp_verify_cur="__OPP_READ_ERROR__"
                    for _opp_rtry in 1 2 3; do
                        if _opp_verify_cur="$(oc get managedcluster "${_OPP_MC_NAME}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    labels = d["metadata"].get("labels", {})
    if sys.argv[1] not in labels:
        print("<absent>")
    else:
        v = labels.get(sys.argv[1])
        print(v if v is not None else "")
except Exception:
    print("__OPP_READ_ERROR__")
    raise SystemExit(1)
' "${_opp_key}" 2>/dev/null)" && [[ "${_opp_verify_cur}" != "__OPP_READ_ERROR__" ]]; then
                            break
                        fi
                        _opp_verify_cur="__OPP_READ_ERROR__"
                        sleep 2
                    done
                    if [[ "${_opp_verify_cur}" == "__OPP_READ_ERROR__" ]]; then
                        echo "ERROR: post-repair verification read failed for ${_opp_key}" >&2
                        echo "verification post-repair read error for ${_opp_key}" >> "${_OPP_EVIDENCE_DIR}/04-label-restore.log" 2>&1 || true
                        _opp_restore_ok=0
                        continue
                    fi
                    if [[ "${_opp_verify_pre}" != "${_opp_verify_cur}" ]]; then
                        echo "ERROR: label ${_opp_key} restore verification failed" >&2
                        echo "label ${_opp_key} mismatch" >> "${_OPP_EVIDENCE_DIR}/04-label-restore.log" 2>&1 || true
                        _opp_restore_ok=0
                    fi
                fi
            done
            rm -f "${_opp_verify_json}"
        fi
        set -x
        if (( _opp_restore_ok == 0 )); then
            echo "OPP label restore verification FAILED" >&2
        fi
    else
        _opp_restore_ok=0
    fi

    # Wait (bounded, up to 5 minutes) for the placement to re-select
    # local-cluster after the label restore. The placement controller
    # records selected cluster names in PlacementDecision resources, not
    # in Placement.status; check the decisions first and fall back to the
    # Placement status fields for older API shapes.
    typeset -i _opp_sel=0
    typeset -i _opp_try=0
    while (( _opp_try < 30 )); do
        _opp_dec="no"
        if [[ "$(oc get placementdecision "-n${_OPP_PLACEMENT_NS}" -l "cluster.open-cluster-management.io/placement=${_OPP_PLACEMENT_NAME}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    names = []
    for item in d.get("items", []):
        for dec in item.get("status", {}).get("decisions", []) or []:
            if dec.get("clusterName"):
                names.append(dec["clusterName"])
    print("yes" if "local-cluster" in names else "no")
except Exception:
    print("no")
')" == "yes" ]]; then
            _opp_dec="yes"
        else
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
        fi
        if [[ "${_opp_dec}" == "yes" ]]; then
            _opp_sel=1
            break
        fi
        _opp_try=$((_opp_try + 1))
        sleep 10
    done

    # Post-suite placement state and decisions as evidence.
    # Raw snapshots are staged outside ARTIFACT_DIR; publish only after
    # both scrub passes succeed (same discipline as the pre-suite block).
    # Tracing off: the scrub below expands ${_secrets_pattern}, and traced
    # expansions of it write the collected secret values into build-log.txt.
    set +x
    _OPP_POST_RAW_STAGING=""
    _mk_tmpdir _OPP_POST_RAW_STAGING
    if [[ -z "${_OPP_POST_RAW_STAGING}" ]]; then
        echo "ERROR: cannot allocate OPP post-suite staging directory" >&2
        _OPP_SNAPSHOT_FAILED=1
    else
        mkdir -p "${_OPP_POST_RAW_STAGING}" "${_OPP_EVIDENCE_DIR}"
        oc get placement "-n${_OPP_PLACEMENT_NS}" "${_OPP_PLACEMENT_NAME}" -o json 2>/dev/null | \
            python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({
    "name": d["metadata"]["name"],
    "namespace": d["metadata"]["namespace"],
    "status": d.get("status", {})
}, indent=2))
' > "${_OPP_POST_RAW_STAGING}/05-placement-status-post.json" 2>&1
        oc get placementdecision "-n${_OPP_PLACEMENT_NS}" -l "cluster.open-cluster-management.io/placement=${_OPP_PLACEMENT_NAME}" -o json 2>/dev/null | \
            python3 -c '
import json, sys
d = json.load(sys.stdin)
result = []
for item in d.get("items", []):
    result.append({
        "name": item["metadata"]["name"],
        "decisions": item.get("status", {}).get("decisions")
    })
print(json.dumps(result, indent=2))
' > "${_OPP_POST_RAW_STAGING}/06-placementdecisions-post.json" 2>&1
        for _opp_f in "${_OPP_POST_RAW_STAGING}"/*.json; do
            [[ -f "${_opp_f}" ]] || continue
            _opp_tmp=""
            _mk_tmp _opp_tmp
            _opp_dest="${_OPP_EVIDENCE_DIR}/$(basename "${_opp_f}")"
            typeset -i _opp_scrub_ok=1
            if [[ -n "${_secrets_pattern}" ]]; then
                if ! sed -E "s/${_secrets_pattern}/[REDACTED]/g" "${_opp_f}" > "${_opp_tmp}"; then
                    echo "ERROR: OPP evidence value scrub failed for ${_opp_f}" >&2
                    _opp_scrub_ok=0
                    rm -f "${_opp_tmp}"
                fi
            else
                if ! cp "${_opp_f}" "${_opp_tmp}"; then
                    echo "ERROR: OPP evidence staging copy failed for ${_opp_f}" >&2
                    _opp_scrub_ok=0
                    rm -f "${_opp_tmp}"
                fi
            fi
            if (( _opp_scrub_ok )); then
                if ! _scrub_leaktk_patterns -i "${_opp_tmp}"; then
                    echo "ERROR: OPP evidence pattern scrub failed for ${_opp_f}" >&2
                    _opp_scrub_ok=0
                    rm -f "${_opp_tmp}"
                fi
            fi
            if (( _opp_scrub_ok )); then
                if ! mv "${_opp_tmp}" "${_opp_dest}"; then
                    echo "ERROR: OPP evidence publish failed for ${_opp_dest}" >&2
                    _opp_scrub_ok=0
                fi
            fi
            if (( _opp_scrub_ok )); then
                :
            else
                rm -f "${_opp_tmp}" "${_opp_dest}"
                echo "WARNING: ${_opp_f} was not published to ${_opp_dest}" >&2
                _OPP_SNAPSHOT_FAILED=1
            fi
        done
        rm -rf "${_OPP_POST_RAW_STAGING}"
    fi
    set -x

    # JUnit rows for the checks (INTEROP-9711 done-when evidence).
    typeset -i _opp_inv_ok=0
    if [[ "${_OPP_POLICY_COUNT}" -gt 0 ]]; then
        _opp_inv_ok=1
    fi
    typeset -i _opp_base_ok="${_OPP_BASELINE_OK}"
    typeset -i _opp_failures=$(( (1 - _opp_inv_ok) + (1 - _opp_sel) + (1 - _opp_base_ok) + (1 - _opp_restore_ok) ))
    _opp_junit="${ARTIFACT_DIR}/junit_grc_placement_restore.xml"
    _opp_junit_tmp=""
    _mk_tmp _opp_junit_tmp
    typeset -i _opp_junit_write_ok=0
    set +x
    if [[ -n "${_opp_junit_tmp}" ]]; then
        if {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo "<testsuite name=\"lp-interop--ACM--OPP--grc-placement-restore\" tests=\"4\" failures=\"${_opp_failures}\">"
            echo "  <testcase classname=\"grc-placement-restore\" name=\"operatorpolicy-inventory-nonempty\">"
            if [[ "${_opp_inv_ok}" -ne 1 ]]; then
                if [[ "${_OPP_QUERY_FAILED}" -eq 1 ]]; then
                    echo "    <failure message=\"$(_opp_xesc "pre-GRC capture never ran: the OPP placement query failed (rc=${_OPP_QUERY_RC}); see 00-placement-query-error.log")\"></failure>"
                else
                    echo "    <failure message=\"$(_opp_xesc "operatorpolicy inventory at pre-GRC capture: ${_OPP_POLICY_COUNT} objects")\"></failure>"
                fi
            fi
            echo "  </testcase>"
            echo "  <testcase classname=\"grc-placement-restore\" name=\"label-baseline-readable\">"
            if [[ "${_opp_base_ok}" -ne 1 ]]; then
                echo "    <failure message=\"$(_opp_xesc "pre-suite local-cluster label snapshot unreadable; the label restore was skipped")\"></failure>"
            fi
            echo "  </testcase>"
            echo "  <testcase classname=\"grc-placement-restore\" name=\"placement-selects-local-cluster\">"
            if [[ "${_opp_sel}" -ne 1 ]]; then
                echo "    <failure message=\"$(_opp_xesc "placement ${_OPP_PLACEMENT_NAME} does not select ${_OPP_MC_NAME} after the GRC suite; see 04-label-restore.log, 05-placement-status-post.json and 06-placementdecisions-post.json in this step artifacts")\"></failure>"
            fi
            echo "  </testcase>"
            echo "  <testcase classname=\"grc-placement-restore\" name=\"label-restore-verified\">"
            if [[ "${_opp_restore_ok}" -ne 1 ]]; then
                echo "    <failure message=\"$(_opp_xesc "label restore verification failed; see 04-label-restore.log")\"></failure>"
            fi
            echo "  </testcase>"
            echo "</testsuite>"
        } > "${_opp_junit_tmp}" 2>&1; then
            if python3 -c 'import xml.etree.ElementTree as ET, sys; ET.parse(sys.argv[1])' "${_opp_junit_tmp}" 2>&1; then
                if mv "${_opp_junit_tmp}" "${_opp_junit}" 2>&1; then
                    _opp_junit_write_ok=1
                else
                    echo "ERROR: placement carrier publish failed for ${_opp_junit}" >&2
                    rm -f "${_opp_junit}" "${_opp_junit_tmp}"
                fi
            else
                echo "ERROR: placement carrier XML validation failed" >&2
                rm -f "${_opp_junit}" "${_opp_junit_tmp}"
            fi
        else
            echo "ERROR: placement carrier write failed" >&2
            rm -f "${_opp_junit}" "${_opp_junit_tmp}"
        fi
    else
        echo "ERROR: placement carrier temp allocation failed" >&2
        rm -f "${_opp_junit}"
    fi
    if (( _opp_junit_write_ok == 0 )); then
        if [[ "${_test_rc}" -eq 0 ]]; then
            _test_rc=1
        fi
    fi
    set -x
    # Backup atomically: a partial copy must never leave a truncated file at
    # the path the EXIT trap restores from. Only backup a validated carrier.
    if (( _opp_junit_write_ok )); then
        _opp_backup_tmp=""
        if ! _opp_backup_tmp="$(mktemp /tmp/junit_grc_placement_restore_backup.XXXXXX 2>/dev/null)" ||
            ! cp "${_opp_junit}" "${_opp_backup_tmp}" ||
            ! mv "${_opp_backup_tmp}" "/tmp/junit_grc_placement_restore_backup.xml"; then
            echo "ERROR: placement restore JUnit backup failed for ${_opp_junit}" >&2
            rm -f "${_opp_backup_tmp:-}"
            if [[ "${_test_rc}" -eq 0 ]]; then
                _test_rc=1
            fi
        fi
    fi
    if [[ "${_opp_failures}" -gt 0 ]]; then
        echo "OPP placement checks FAILED; see ${_opp_junit}" >&2
        if [[ "${_test_rc}" -eq 0 ]]; then
            _test_rc=1
        fi
    fi
fi

# A temp allocation that failed anywhere, or OPP snapshots skipped because no
# staging directory could be allocated, means evidence is missing: report a
# step failure instead of a silent green run.
# The private baseline is not needed once the step is done; leave no
# unscrubbed copy behind.
rm -f "${_opp_baseline_private:-}"
if (( _tmp_alloc_failed || _OPP_SNAPSHOT_FAILED )); then
    echo "ERROR: evidence staging was unusable in this step; marking the step failed" >&2
    if [[ "${_test_rc}" -eq 0 ]]; then
        _test_rc=1
    fi
fi

exit "${_test_rc}"
