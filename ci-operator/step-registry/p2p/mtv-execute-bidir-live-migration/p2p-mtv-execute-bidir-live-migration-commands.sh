#!/bin/bash
#
# Execute bi-directional CCLM live migration for a single VM:
#   Pass 1 (forward):  MTV_SOURCE_PROVIDER  → MTV_DESTINATION_PROVIDER
#   Pass 2 (reverse):  MTV_DESTINATION_PROVIDER → MTV_SOURCE_PROVIDER
#
# After Pass 1 the VM resides on the destination spoke; Pass 2 migrates it back.
# Both passes reuse the same preflights, Plan/Migration pattern, and JUnit recording.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -r junitFile="${TMPDIR:-/tmp}/cclm-bidir-junit-$$.tsv"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"

HubOc() { oc --kubeconfig="${KUBECONFIG}" "$@"; }

# ---- Helper: JUnit recording -----------------------------------------------

JStep() {
    typeset name="${1:?}"; shift
    typeset -i t0=$SECONDS rc=0
    "$@" || rc=$?
    typeset -i elapsed=$(( SECONDS - t0 ))
    if (( rc == 0 )); then
        printf 'PASS\t%s\t%d\t\n' "${name}" "${elapsed}" >> "${junitFile}"
    else
        printf 'FAIL\t%s\t%d\tFailed (rc=%d)\n' "${name}" "${elapsed}" "${rc}" >> "${junitFile}"
    fi
    return "${rc}"
}

XmlEscape() {
    typeset s="${1}"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
    s="${s//\"/&quot;}"; s="${s//\'/&apos;}"
    printf '%s' "${s}"
}

WriteJunit() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    [[ -f "${junitFile}" ]] || return 0
    typeset xmlFile="${ARTIFACT_DIR}/junit_cclm_bidir_migration.xml"
    mkdir -p "${ARTIFACT_DIR}"
    typeset -i total=0 failures=0 totalTime=0
    typeset status name elapsed failMsg
    while IFS=$'\t' read -r status name elapsed failMsg; do
        (( total++ )) || true
        (( totalTime += elapsed )) || true
        [[ "${status}" == "FAIL" ]] && (( failures++ )) || true
    done < "${junitFile}"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuite name="cclm-bidir-migration" tests="%d" failures="%d" errors="0" skipped="0" time="%d">\n' \
            "${total}" "${failures}" "${totalTime}"
        while IFS=$'\t' read -r status name elapsed failMsg; do
            typeset escapedName; escapedName="$(XmlEscape "${name}")"
            printf '  <testcase name="%s" classname="cclm-bidir-migration" time="%d">\n' \
                "${escapedName}" "${elapsed}"
            if [[ "${status}" == "FAIL" ]]; then
                typeset escapedMsg; escapedMsg="$(XmlEscape "${failMsg}")"
                printf '    <failure message="%s">%s</failure>\n' \
                    "${escapedMsg}" "${escapedMsg}"
            fi
            printf '  </testcase>\n'
        done < "${junitFile}"
        printf '</testsuite>\n'
    } > "${xmlFile}"
    : "JUnit written → ${xmlFile} (${total} tests, ${failures} failures)"
    rm -f "${junitFile}"
}

# ---- Helper: spoke kubeconfig resolution ------------------------------------

ResolveKubeconfig() {
    typeset spokeIndex="${1:?}"
    typeset explicit="${2:-}"

    if [[ -n "${explicit}" ]]; then
        printf '%s' "${explicit}"
        return 0
    fi
    if [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${spokeIndex}" ]]; then
        printf '%s' "${SHARED_DIR}/managed-cluster-kubeconfig-${spokeIndex}"
        return 0
    fi
    if (( spokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        printf '%s' "${SHARED_DIR}/managed-cluster-kubeconfig"
        return 0
    fi
    : "Kubeconfig not found for spoke index ${spokeIndex}"
    false
}

# ---- Helper: CCLM gate check/enable ----------------------------------------

HasCclmGate() {
    typeset kc="${1:?}"
    oc --kubeconfig="${kc}" get kubevirt "${MTV_KUBEVIRT_NAME}" -n "${MTV_CNV_NAMESPACE}" -o json \
        | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
        > /dev/null
}

EnsureCclmGate() {
    typeset kc="${1:?}"
    HasCclmGate "${kc}" && return 0
    oc --kubeconfig="${kc}" patch hyperconverged "${MTV_HCO_NAME}" -n "${MTV_CNV_NAMESPACE}" \
        --type merge -p '{"spec":{"featureGates":{"decentralizedLiveMigration":true}}}'
    typeset -i deadline=$((SECONDS + 600))
    while (( SECONDS < deadline )); do
        HasCclmGate "${kc}" && return 0
        sleep 10
    done
    false
}
export -f HasCclmGate EnsureCclmGate

# ---- Helper: ParseOcWaitDurationSeconds -------------------------------------

ParseOcWaitDurationSeconds() {
    typeset duration="${1:?}"
    if [[ "${duration}" =~ ^([0-9]+)h$ ]]; then printf '%d\n' $(( BASH_REMATCH[1] * 3600 ))
    elif [[ "${duration}" =~ ^([0-9]+)m$ ]]; then printf '%d\n' $(( BASH_REMATCH[1] * 60 ))
    elif [[ "${duration}" =~ ^([0-9]+)s$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"
    else printf '%d\n' 7200; fi
}

# ---- RunPass — execute one migration direction ------------------------------
#
# Args:
#   $1  pass label       e.g. "Forward (spoke-1 → spoke-2)"
#   $2  srcProvider      MTV Provider CR name on the hub
#   $3  dstProvider      MTV Provider CR name on the hub
#   $4  srcKubeconfig    path to source spoke kubeconfig
#   $5  dstKubeconfig    path to destination spoke kubeconfig
#   $6  planName         Plan CR name
#   $7  migrationName    Migration CR name
#
RunPass() {
    typeset label="${1:?}"
    typeset srcProv="${2:?}"
    typeset dstProv="${3:?}"
    typeset srcKc="${4:?}"
    typeset dstKc="${5:?}"
    typeset planName="${6:?}"
    typeset migName="${7:?}"
    # MTV_TEST_VM_TARGET_NAMESPACE defaults to "" in ref.yaml; fall back to source namespace
    typeset targetNs="${MTV_TEST_VM_TARGET_NAMESPACE:-${MTV_TEST_VM_NAMESPACE}}"

    SrcOc() { oc --kubeconfig="${srcKc}" "$@"; }
    DstOc() { oc --kubeconfig="${dstKc}" "$@"; }

    DumpPassDiagnostics() {
        [[ -n "${ARTIFACT_DIR}" ]] || return 0
        typeset diagDir="${ARTIFACT_DIR}/bidir-${planName}-diagnostics"
        mkdir -p "${diagDir}"
        HubOc get plan,migration -n "${MTV_NAMESPACE}" > "${diagDir}/hub-mtv.txt" 2>&1 || true
        HubOc describe "plan/${planName}" -n "${MTV_NAMESPACE}" > "${diagDir}/plan.txt" 2>&1 || true
        HubOc describe "migration/${migName}" -n "${MTV_NAMESPACE}" > "${diagDir}/migration.txt" 2>&1 || true
        SrcOc get vm,vmi -n "${MTV_TEST_VM_NAMESPACE}" -o wide > "${diagDir}/src-vms.txt" 2>&1 || true
        DstOc get vm,vmi -n "${targetNs}" -o wide > "${diagDir}/dst-vms.txt" 2>&1 || true
    }

    WaitMigrationSucceeded() {
        typeset -i deadline
        typeset succeededStatus failedStatus
        deadline=$((SECONDS + $(ParseOcWaitDurationSeconds "${MTV_MIGRATION_TIMEOUT}")))
        while (( SECONDS < deadline )); do
            succeededStatus="$(HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' || true)"
            failedStatus="$(HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)"
            [[ "${succeededStatus}" == "True" ]] && return 0
            if [[ "${failedStatus}" == "True" ]]; then
                HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
                    -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' \
                    1>&2 || true
                return 1
            fi
            : "${label}: migration in progress (${SECONDS}/${deadline}s)"
            sleep "${MTV_MIGRATION_POLL_INTERVAL_SECONDS}"
        done
        : "${label}: migration timed out after ${MTV_MIGRATION_TIMEOUT}"
        return 1
    }

    # Idempotent apply: adds last-applied-configuration annotation for proper 3-way merge on re-runs
    ApplyManifest_() {
        HubOc create -f - --dry-run=client -o yaml --save-config | HubOc apply -f -
    }

    typeset -i passRc=0
    (
        trap 'DumpPassDiagnostics' ERR

        JStep "${label}: Preflight: Providers Ready" \
            bash -c "
                oc --kubeconfig=\"${KUBECONFIG}\" wait \"provider/${srcProv}\" \
                    -n \"${MTV_NAMESPACE}\" --for=condition=Ready --timeout=\"${MTV_PLAN_READY_TIMEOUT}\"
                oc --kubeconfig=\"${KUBECONFIG}\" wait \"provider/${dstProv}\" \
                    -n \"${MTV_NAMESPACE}\" --for=condition=Ready --timeout=\"${MTV_PLAN_READY_TIMEOUT}\"
            "

        JStep "${label}: Preflight: CCLM Gates" \
            bash -c "EnsureCclmGate \"${srcKc}\"; EnsureCclmGate \"${dstKc}\""

        JStep "${label}: Preflight: Sync Controllers Ready" \
            bash -c "
                oc --kubeconfig=\"${srcKc}\" wait deployment/virt-synchronization-controller \
                    -n \"${MTV_CNV_NAMESPACE}\" --for=condition=Available --timeout=\"${MTV_SYNC_CONTROLLER_WAIT}\"
                oc --kubeconfig=\"${dstKc}\" wait deployment/virt-synchronization-controller \
                    -n \"${MTV_CNV_NAMESPACE}\" --for=condition=Available --timeout=\"${MTV_SYNC_CONTROLLER_WAIT}\"
            "

        JStep "${label}: Preflight: Source VM Running" \
            bash -c "
                phase=\$(oc --kubeconfig=\"${srcKc}\" get \
                    \"virtualmachineinstance/${MTV_TEST_VM_NAME}\" \
                    -n \"${MTV_TEST_VM_NAMESPACE}\" \
                    -o jsonpath='{.status.phase}' || true)
                [[ \"\${phase}\" == \"Running\" ]]
            "

        JStep "${label}: Migration: Refresh Provider Inventory" \
            bash -c "
                ts=\$(date -u +%s)
                oc --kubeconfig=\"${KUBECONFIG}\" annotate \"provider/${srcProv}\" \
                    -n \"${MTV_NAMESPACE}\" \"forklift.konveyor.io/inventory-refresh=\${ts}\" --overwrite
                oc --kubeconfig=\"${KUBECONFIG}\" annotate \"provider/${dstProv}\" \
                    -n \"${MTV_NAMESPACE}\" \"forklift.konveyor.io/inventory-refresh=\${ts}\" --overwrite
                oc --kubeconfig=\"${KUBECONFIG}\" wait \"provider/${srcProv}\" \
                    -n \"${MTV_NAMESPACE}\" --for=condition=Ready --timeout=\"${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}\"
                oc --kubeconfig=\"${KUBECONFIG}\" wait \"provider/${dstProv}\" \
                    -n \"${MTV_NAMESPACE}\" --for=condition=Ready --timeout=\"${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}\"
            "

        JStep "${label}: Migration: Apply Plan" \
            ApplyManifest_ <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: ${planName}
  namespace: ${MTV_NAMESPACE}
spec:
  provider:
    source:
      name: ${srcProv}
      namespace: ${MTV_NAMESPACE}
    destination:
      name: ${dstProv}
      namespace: ${MTV_NAMESPACE}
  targetNamespace: ${targetNs}
  map:
    network:
      name: ${MTV_NETWORK_MAP_NAME}
      namespace: ${MTV_NAMESPACE}
    storage:
      name: ${MTV_STORAGE_MAP_NAME}
      namespace: ${MTV_NAMESPACE}
  vms:
  - name: ${MTV_TEST_VM_NAME}
    namespace: ${MTV_TEST_VM_NAMESPACE}
  type: live
EOF

        JStep "${label}: Migration: Plan Ready" \
            HubOc wait "plan/${planName}" -n "${MTV_NAMESPACE}" \
                --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"

        JStep "${label}: Migration: Apply Migration" \
            ApplyManifest_ <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: ${migName}
  namespace: ${MTV_NAMESPACE}
spec:
  plan:
    name: ${planName}
    namespace: ${MTV_NAMESPACE}
EOF

        JStep "${label}: Migration: Succeeded" WaitMigrationSucceeded

        JStep "${label}: Verification: Destination VMI Running" \
            bash -c "
                phase=\$(oc --kubeconfig=\"${dstKc}\" get \
                    \"virtualmachineinstance/${MTV_TEST_VM_NAME}\" \
                    -n \"${targetNs}\" \
                    -o jsonpath='{.status.phase}' || true)
                [[ \"\${phase}\" == \"Running\" ]]
            "

        true
    ) || passRc=$?

    if (( passRc != 0 )); then
        DumpPassDiagnostics
    fi

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            HubOc get "plan/${planName}" "migration/${migName}" -n "${MTV_NAMESPACE}" -o wide
            SrcOc get vm,vmi -n "${MTV_TEST_VM_NAMESPACE}" -o wide
            DstOc get vm,vmi -n "${targetNs}" -o wide
        } > "${ARTIFACT_DIR}/bidir-${planName}-status.txt" 2>&1 || true
    fi

    return "${passRc}"
}

# ---- Main -------------------------------------------------------------------

typeset srcKc dstKc
srcKc="$(ResolveKubeconfig "${MTV_SOURCE_SPOKE_INDEX}" "${MTV_SOURCE_SPOKE_KUBECONFIG}")"
dstKc="$(ResolveKubeconfig "${MTV_DEST_SPOKE_INDEX}"   "${MTV_DEST_SPOKE_KUBECONFIG}")"
[[ -r "${srcKc}" ]]
[[ -r "${dstKc}" ]]

typeset -i overallRc=0

# Pass 1: forward (source → destination)
RunPass \
    "Pass 1 (${MTV_SOURCE_PROVIDER} → ${MTV_DESTINATION_PROVIDER})" \
    "${MTV_SOURCE_PROVIDER}" "${MTV_DESTINATION_PROVIDER}" \
    "${srcKc}" "${dstKc}" \
    "${MTV_BIDIR_FORWARD_PLAN_NAME}" "${MTV_BIDIR_FORWARD_MIGRATION_NAME}" \
|| overallRc=$?

# Pass 2: reverse (destination → source) — same VM, now on destination
RunPass \
    "Pass 2 (${MTV_DESTINATION_PROVIDER} → ${MTV_SOURCE_PROVIDER})" \
    "${MTV_DESTINATION_PROVIDER}" "${MTV_SOURCE_PROVIDER}" \
    "${dstKc}" "${srcKc}" \
    "${MTV_BIDIR_REVERSE_PLAN_NAME}" "${MTV_BIDIR_REVERSE_MIGRATION_NAME}" \
|| overallRc=$?

WriteJunit

if (( overallRc != 0 )); then
    if [[ "${cclmDebugMode}" == "true" ]]; then
        : "WARNING: bi-directional migration failed (rc=${overallRc}); not failing job (debug mode)"
    else
        exit "${overallRc}"
    fi
fi

true
