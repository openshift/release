#!/bin/bash
set -euo pipefail; shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# ACS OPP SMOKE runner (INTEROP-9647 PR-A, team review revision 3 D4/D6/D7)
#
# Contract (fail-closed):
#   ACS_EXPECTATION   required | absent-by-design   (unset/other => exit 2)
#   Classification runs BEFORE any SHARED_DIR consumption, by this step's
#   own query (the image ships oc): present / absent (0-exit read, 0 items)
#   / unknown (read failure after 3 attempts => FAILED, exit != 0).
#   Carrier junit lp-interop--OPP--acs-smoke is emitted on every exit path.
#   Exit codes: 0 pass / absent-by-design; 1 acs-required-but-absent or
#   test failure; 2 invalid input; 3 acs-state-indeterminate.
# ---------------------------------------------------------------------------

if [[ -f "${SHARED_DIR:-}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

ACS_EXPECTATION="${ACS_EXPECTATION:-}"
ACS_SELFTEST="${ACS_SELFTEST:-true}"

# --- JUnit carrier machinery (deploy-acs precedent, D4/D6) -----------------
_SUITE="lp-interop--OPP--acs-smoke"
_CLASSNAME="lp-interop.OPP.acs-smoke"
_CARRIER="${ARTIFACT_DIR}/junit_${_SUITE}.xml"
_junit_start=$(date +%s)
declare -a _CASES=()
declare -i _N_FAILURES=0 _N_SKIPPED=0 _N_TOTAL=0 _FINALIZED=0
_ACS_STATE="unclassified"
_CLASSIFICATION_CASE=""

_xesc() {
    python3 -c 'import sys, xml.sax.saxutils as x; sys.stdout.write(x.escape(sys.argv[1]))' "$1"
}

_add_case() {
    typeset name="$1" status="$2" type="${3:-}" msg="${4:-}"
    typeset body=""
    if [[ "${status}" == "failed" ]]; then
        _N_FAILURES+=1
        body="<failure message=\"$(_xesc "${msg}")\" type=\"$(_xesc "${type}")\">$(_xesc "${msg}")</failure>"
    elif [[ "${status}" == "skipped" ]]; then
        _N_SKIPPED+=1
        body="<skipped message=\"$(_xesc "${msg}")\"/>"
    fi
    _CASES+=("<testcase name=\"$(_xesc "${name}")\" classname=\"${_CLASSNAME}\">${body}</testcase>")
    _N_TOTAL+=1
}

_add_classification() {
    _CLASSIFICATION_CASE="$1"
    _add_case "$@"
}

_write_carrier() {
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"${_SUITE}\" tests=\"${_N_TOTAL}\" failures=\"${_N_FAILURES}\" errors=\"0\" skipped=\"${_N_SKIPPED}\" time=\"$(( $(date +%s) - _junit_start ))\">"
        typeset c=""
        for c in "${_CASES[@]:-}"; do
            [[ -n "${c}" ]] && echo "  ${c}"
        done
        echo '</testsuite>'
    } > "${_CARRIER}" 2>/dev/null || true
}

_write_shared_copy() {
    # D4 channel split: only the absent-by-design case is downgraded in the
    # SHARED_DIR reporter copy (the PASSED absent-by-design case lives in
    # ${ARTIFACT_DIR} only). A required-but-absent failure is NEVER downgraded:
    # the reporter copy must carry the honest <failure> element.
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    mkdir -p "${SHARED_DIR}/junit" 2>/dev/null || true
    if [[ "${_ACS_STATE}" == "absent" && "${ACS_EXPECTATION}" == "absent-by-design" ]]; then
        {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo "<testsuite name=\"${_SUITE}\" tests=\"${_N_TOTAL}\" failures=\"${_N_FAILURES}\" errors=\"0\" skipped=\"$(( _N_SKIPPED + 1 ))\" time=\"$(( $(date +%s) - _junit_start ))\">"
            typeset c=""
            for c in "${_CASES[@]:-}"; do
                [[ -n "${c}" ]] || continue
                if [[ "${c}" == *"<testcase name=\"${_CLASSIFICATION_CASE}\""* ]]; then
                    echo "  <testcase name=\"${_CLASSIFICATION_CASE}\" classname=\"${_CLASSNAME}\"><skipped/></testcase>"
                else
                    echo "  ${c}"
                fi
            done
            echo '</testsuite>'
        } > "${SHARED_DIR}/junit/junit_${_SUITE}.xml" 2>/dev/null || true
    else
        cp "${_CARRIER}" "${SHARED_DIR}/junit/" 2>/dev/null || true
    fi
}

_finalize() {
    (( _FINALIZED )) && return 0
    _FINALIZED=1
    _write_carrier
    _write_shared_copy
}

# Pre-seed a default-failing carrier: a hard SIGKILL before classification
# leaves a failing artifact on disk (never green; D6 / 9525 contract).
_ACS_STATE="unknown"
_add_classification "acs-state-indeterminate" failed "PreSeed" "carrier pre-seed: step exited before classification completed (SIGKILL guard)"
_write_carrier
_CASES=()
_N_FAILURES=0 _N_SKIPPED=0 _N_TOTAL=0
_CLASSIFICATION_CASE=""
_ACS_STATE="unclassified"

_terminate() {
    typeset sig="$1"
    if [[ "${_ACS_STATE}" == "unclassified" ]]; then
        _ACS_STATE="unknown"
        _add_classification "acs-state-indeterminate" failed "StepTerminated" "terminated by ${sig} before classification completed"
    else
        _add_case "step-terminated" failed "StepTerminated" "terminated by ${sig} after classification (state=${_ACS_STATE})"
    fi
    exit 143
}
trap '_terminate TERM' TERM
trap '_terminate INT' INT

# shellcheck disable=SC2317
_propagate_junit () {
    # Copy the SMOKE suite's own JUnit results to SHARED_DIR/junit for the
    # reporters.  The carrier file is excluded here: its SHARED_DIR copy is
    # governed by the D4 channel split in _write_shared_copy.
    [[ -n "${SHARED_DIR:-}" ]] || return 0
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -maxdepth 1 -name '*.xml' \
        ! -name "junit_${_SUITE}.xml" \
        -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
}

_jrc=0
trap '_jrc=$?; set +e; set +x; if (( _jrc != 0 && _N_FAILURES == 0 )); then _add_case "step-exited-nonzero" failed "StepExit" "step exited ${_jrc} without a recorded failure (state=${_ACS_STATE:-unclassified})"; fi; _propagate_junit; _finalize; exit "${_jrc}"' EXIT

# ---------------------------------------------------------------------------
# Self-test (D6 named executor): machinery validation, always on
# ---------------------------------------------------------------------------
_run_selftest() {
    typeset -i st_rc=0
    [[ -w "${ARTIFACT_DIR}" ]] || { echo "[smoke-selftest] FAIL: ARTIFACT_DIR not writable"; st_rc=1; }
    command -v oc >/dev/null 2>&1 || { echo "[smoke-selftest] FAIL: oc not found"; st_rc=1; }
    command -v python3 >/dev/null 2>&1 || { echo "[smoke-selftest] FAIL: python3 not found"; st_rc=1; }
    if (( st_rc == 0 )); then
        _add_case "acs-preflight-selftest" passed
    else
        _add_case "acs-preflight-selftest" failed "SelfTest" "acs-preflight-selftest failed: machinery validation"
    fi
    return "${st_rc}"
}

# ---------------------------------------------------------------------------
# Classification (D4): own query, BEFORE consuming SHARED_DIR
# ---------------------------------------------------------------------------
_classify() {
    typeset out="" items="" attempt=""
    typeset -i rc=0
    for attempt in 1 2 3; do
        if out="$(oc get centrals.platform.stackrox.io -A -o json 2>/dev/null)"; then
            items="$(printf '%s' "${out}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items",[])))' 2>/dev/null)" || rc=1
            if (( rc == 0 )); then
                if (( items > 0 )); then
                    _ACS_STATE="present"
                else
                    _ACS_STATE="absent"
                fi
                return 0
            fi
        fi
        rc=0
        sleep $(( attempt * 2 ))
    done
    _ACS_STATE="unknown"
    return 0
}

# --- Fail-closed expectation validation (D4) -------------------------------
case "${ACS_EXPECTATION}" in
    required|absent-by-design)
        echo "[smoke] ACS_EXPECTATION=${ACS_EXPECTATION}"
        ;;
    *)
        _ACS_STATE="unknown"
        _add_classification "acs-expectation-invalid" failed "InvalidInput" \
            "ACS_EXPECTATION must be 'required' or 'absent-by-design' (got: '${ACS_EXPECTATION:-unset}'); fail-closed"
        echo "[smoke] FATAL: invalid ACS_EXPECTATION '${ACS_EXPECTATION:-unset}'"
        exit 2
        ;;
esac

if [[ "${ACS_SELFTEST}" != "false" ]]; then
    if ! _run_selftest; then
        exit 2
    fi
fi

_classify
echo "[smoke] ACS state classified: ${_ACS_STATE}"

if [[ "${_ACS_STATE}" == "unknown" ]]; then
    _add_classification "acs-state-indeterminate" failed "Classification" \
        "acs-unclassified:central-query/read failed after 3 attempts; never classified as absent without a successful read"
    exit 3
fi

if [[ "${_ACS_STATE}" == "absent" ]]; then
    if [[ "${ACS_EXPECTATION}" == "required" ]]; then
        _add_classification "acs-required-but-absent" failed "Classification" \
            "acs-central-not-created: Central CR absent on a successful read while ACS_EXPECTATION=required"
        echo "[smoke] Central CR absent but required by ACS_EXPECTATION"
        exit 1
    fi
    _add_classification "acs-absent-by-design" passed
    echo "[smoke] Central CR absent by design (ACS_EXPECTATION=absent-by-design); nothing to smoke-test"
    exit 0
fi

_add_classification "acs-present" passed

# ---------------------------------------------------------------------------
# Present: run the SMOKE suite (existing flow)
# ---------------------------------------------------------------------------
echo "[smoke] Reading connection details from SHARED_DIR..."

typeset centralUrl=''
centralUrl="$(cat "${SHARED_DIR}/CENTRAL_URL")"
ROX_ADMIN_PASSWORD="$(cat "${SHARED_DIR}/ROX_ADMIN_PASSWORD")"

echo "[smoke] Connection details loaded from SHARED_DIR"

STACKROX_REF="${STACKROX_REF:-master}"
SCANNER_REF="${SCANNER_REF:-master}"

echo "[smoke] Sparse-cloning stackrox/stackrox..."
cd /tmp
rm -rf stackrox scanner
git clone --depth 1 --filter=blob:none --sparse --branch "${STACKROX_REF}" \
    https://github.com/stackrox/stackrox.git stackrox
cd stackrox
git sparse-checkout set qa-tests-backend/ proto/

echo "[smoke] Fetching scanner protos..."
git clone --depth 1 --filter=blob:none --sparse --branch "${SCANNER_REF}" \
    https://github.com/stackrox/scanner.git /tmp/scanner
cd /tmp/scanner
git sparse-checkout set proto/scanner
cp -r proto/scanner /tmp/stackrox/qa-tests-backend/src/main/proto/scanner
chmod -R u+w /tmp/stackrox/qa-tests-backend/src/main/proto/scanner

echo "[smoke] Materializing proto sources (replace symlinks with copies)..."
cd /tmp/stackrox/qa-tests-backend/src/main/proto
typeset target=''
for link in api internalapi storage test tools; do
    if [[ -L "${link}" ]]; then
        target="$(readlink -f "${link}")"
        rm "${link}"
        cp -r "${target}" "${link}"
    fi
done

echo "[smoke] Patching DEFAULT_CLUSTER_NAME to 'local-cluster'..."
sed -i 's/DEFAULT_CLUSTER_NAME = "remote"/DEFAULT_CLUSTER_NAME = "local-cluster"/' \
    /tmp/stackrox/qa-tests-backend/src/main/groovy/services/ClusterService.groovy
grep -q 'DEFAULT_CLUSTER_NAME = "local-cluster"' \
    /tmp/stackrox/qa-tests-backend/src/main/groovy/services/ClusterService.groovy \
    || { echo "[smoke] FATAL: DEFAULT_CLUSTER_NAME patch failed"; exit 1; }

export API_HOSTNAME="${centralUrl}"
export API_PORT="443"
export ROX_USERNAME="admin"
export ROX_ADMIN_PASSWORD
export CLUSTER="OPENSHIFT"
export CI="true"
export POD_SECURITY_POLICIES="false"
export TEST_TARGET="smoke-test"
REGISTRY_USERNAME="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/QUAY_RHACS_ENG_RO_USERNAME)"
export REGISTRY_USERNAME
REGISTRY_PASSWORD="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/QUAY_RHACS_ENG_RO_PASSWORD)"
export REGISTRY_PASSWORD
if [[ -f /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_CREDENTIALS_GCR_SCANNER_V2 ]]; then
    GOOGLE_CREDENTIALS_GCR_SCANNER_V2="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_CREDENTIALS_GCR_SCANNER_V2)"
    export GOOGLE_CREDENTIALS_GCR_SCANNER_V2
fi
if [[ -f /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2 ]]; then
    GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2)"
    export GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2
fi

# Re-enable trace logging only now that all credentials are loaded (D7:
# no set -x may precede any credential read/echo; static ordering check
# enforces this).
set -x

cd /tmp/stackrox/qa-tests-backend

cat > /tmp/fix-proto-deps.gradle <<'INIT'
allprojects {
    afterEvaluate {
        tasks.matching { it.name == 'compileGroovy' }.configureEach {
            dependsOn tasks.matching { it.name == 'generateProto' }
        }
    }
}
INIT

echo "[smoke] Running testSMOKE..."
typeset -i testExit=0
./gradlew testSMOKE --no-daemon --init-script /tmp/fix-proto-deps.gradle \
    -Dorg.gradle.jvmargs="-Xmx2g" || testExit=$?

echo "[smoke] Copying JUnit results to ARTIFACT_DIR..."
if [[ -d build/test-results/testSMOKE ]]; then
    find build/test-results/testSMOKE -name '*.xml' -exec cp -v {} "${ARTIFACT_DIR}/" \;
fi

if [[ -d build/reports/tests/testSMOKE ]]; then
    mkdir -p "${ARTIFACT_DIR}/smoke-report"
    find build/reports/tests/testSMOKE -mindepth 1 -maxdepth 1 \
        -exec cp -r {} "${ARTIFACT_DIR}/smoke-report/" \;
fi

echo "[smoke] Test run finished with exit code: ${testExit}"
exit "${testExit}"
