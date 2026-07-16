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
    typeset -a fURLArr=()
    type -t wget 1>/dev/null && fURLArr=(wget -nv -O-) || fURLArr=(curl -fsSL)
    "${fURLArr[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
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

    # MTV_TEST_VM_NAMES (comma-separated) takes precedence over MTV_TEST_VM_NAME
    typeset -a vmNamesArr=()
    if [[ -n "${MTV_TEST_VM_NAMES}" ]]; then
        IFS=',' read -ra vmNamesArr <<< "${MTV_TEST_VM_NAMES}"
    else
        vmNamesArr=("${MTV_TEST_VM_NAME}")
    fi
    typeset -i _idx
    for (( _idx=0; _idx<${#vmNamesArr[@]}; _idx++ )); do
        vmNamesArr[_idx]="${vmNamesArr[_idx]// /}"
    done

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
                # Top-level migration conditions
                HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
                    -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' \
                    1>&2 || true
                # Per-VM conditions (detailed failure reason per individual VM)
                HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
                    -o jsonpath='{range .status.vms[*]}{"VM "}{.name}{":"}{"\n"}{range .conditions[*]}{"  "}{.type}{"="}{.status}{" — "}{.message}{"\n"}{end}{end}' \
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

    # Build and apply Plan with all VMs in a single MTV Plan (concurrent migration)
    ApplyPlan_() {
        typeset vmYaml="" vmNameIter
        for vmNameIter in "${vmNamesArr[@]}"; do
            vmYaml+="  - name: ${vmNameIter}"$'\n'
            vmYaml+="    namespace: ${MTV_TEST_VM_NAMESPACE}"$'\n'
        done
        printf '%s' "apiVersion: forklift.konveyor.io/v1beta1
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
${vmYaml}  type: live
" | ApplyManifest_
    }

    # Apply Migration CR (references only the Plan, not individual VMs)
    ApplyMigration_() {
        printf '%s' "apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: ${migName}
  namespace: ${MTV_NAMESPACE}
spec:
  plan:
    name: ${planName}
    namespace: ${MTV_NAMESPACE}
" | ApplyManifest_
    }

    # After a live migration MTV leaves the source VM stopped and its PVC intact.
    # Before each pass, delete the VM *and* the root PVC/DataVolume from the destination
    # so MTV does not hit a naming conflict when it tries to (re-)create them.
    # --ignore-not-found makes every delete a no-op on Pass 1 where the destination is empty.
    ClearDestVms_() {
        typeset vmNameIter dvName
        for vmNameIter in "${vmNamesArr[@]}"; do
            dvName="${vmNameIter}-rootdisk"
            # VM must be deleted first so its ownerRef on the DataVolume is released.
            DstOc delete vm "${vmNameIter}" -n "${targetNs}" \
                --ignore-not-found=true --wait=true --timeout="${MTV_VM_DELETE_TIMEOUT}"
            # DataVolume deletion may be blocked by CDI finalizers; best-effort.
            DstOc delete datavolume "${dvName}" -n "${targetNs}" \
                --ignore-not-found=true --wait=true --timeout="${MTV_VM_DELETE_TIMEOUT}" \
                2>/dev/null || true
            # PVC must be fully deleted before MTV tries to recreate it.
            DstOc delete pvc "${dvName}" -n "${targetNs}" \
                --ignore-not-found=true --wait=true --timeout="${MTV_VM_DELETE_TIMEOUT}"
        done
    }

    # Verify all source VMs have a Running VMI before migration
    CheckSourceVmsRunning_() {
        typeset vmNameIter phase
        for vmNameIter in "${vmNamesArr[@]}"; do
            phase="$(SrcOc get "virtualmachineinstance/${vmNameIter}" \
                -n "${MTV_TEST_VM_NAMESPACE}" \
                -o jsonpath='{.status.phase}' || true)"
            [[ "${phase}" == "Running" ]] || {
                : "VMI ${vmNameIter} not Running on source (phase=${phase})"
                false
            }
        done
    }

    # Verify all destination VMs have a Running VMI after migration
    VerifyDstVmsRunning_() {
        typeset vmNameIter phase
        for vmNameIter in "${vmNamesArr[@]}"; do
            phase="$(DstOc get "virtualmachineinstance/${vmNameIter}" \
                -n "${targetNs}" \
                -o jsonpath='{.status.phase}' || true)"
            [[ "${phase}" == "Running" ]] || {
                : "VMI ${vmNameIter} not Running on destination (phase=${phase})"
                false
            }
        done
    }

    # After a successful live migration MTV stops (and eventually deletes) the source VMI.
    # Assert it is gone so we detect any case where the guest is double-running.
    VerifySrcVmiGone_() {
        typeset vmNameIter
        for vmNameIter in "${vmNamesArr[@]}"; do
            if SrcOc get "virtualmachineinstance/${vmNameIter}" \
                    -n "${MTV_TEST_VM_NAMESPACE}" 2>/dev/null; then
                : "VMI ${vmNameIter} still exists on source after migration — possible double-run"
                false
            fi
            : "VMI ${vmNameIter} is absent from source — OK"
        done
    }

    # Verify each VM's root PVC landed on the destination and is Bound.
    # MTV preserves the PVC name from the source DataVolume (${vmName}-rootdisk).
    VerifyDstPvcsBound_() {
        typeset vmNameIter dvName phase
        for vmNameIter in "${vmNamesArr[@]}"; do
            dvName="${vmNameIter}-rootdisk"
            phase="$(DstOc get "persistentvolumeclaim/${dvName}" \
                -n "${targetNs}" \
                -o jsonpath='{.status.phase}' 2>/dev/null || true)"
            [[ "${phase}" == "Bound" ]] || {
                : "PVC ${dvName} not Bound on destination (phase=${phase:-<not found>})"
                false
            }
            : "PVC ${dvName} is Bound on destination — OK"
        done
    }

    # Verify each destination VMI has an IP address, indicating the guest network stack
    # survived the migration. Retries for MTV_VM_IP_WAIT because IP assignment can lag
    # slightly behind the VMI reaching Running phase.
    VerifyDstVmIPs_() {
        typeset vmNameIter ipAddr
        typeset -i deadline ipWaitSecs
        ipWaitSecs="$(ParseOcWaitDurationSeconds "${MTV_VM_IP_WAIT}")"
        for vmNameIter in "${vmNamesArr[@]}"; do
            deadline=$(( SECONDS + ipWaitSecs ))
            ipAddr=""
            while (( SECONDS < deadline )); do
                ipAddr="$(DstOc get "virtualmachineinstance/${vmNameIter}" \
                    -n "${targetNs}" \
                    -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true)"
                [[ -n "${ipAddr}" ]] && break
                sleep 10
            done
            [[ -n "${ipAddr}" ]] || {
                : "VMI ${vmNameIter} has no IP on destination after ${MTV_VM_IP_WAIT}"
                false
            }
            : "VMI ${vmNameIter} IP on destination: ${ipAddr} — OK"
        done
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

        JStep "${label}: Preflight: Source VMs Running" CheckSourceVmsRunning_

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

        JStep "${label}: Pre-migration: Clear destination VMs if present" ClearDestVms_

        JStep "${label}: Migration: Apply Plan" ApplyPlan_

        JStep "${label}: Migration: Plan Ready" \
            HubOc wait "plan/${planName}" -n "${MTV_NAMESPACE}" \
                --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"

        JStep "${label}: Migration: Apply Migration" ApplyMigration_

        JStep "${label}: Migration: Succeeded" WaitMigrationSucceeded

        # Post-migration verification — all four checks must pass
        JStep "${label}: Verification: Destination VMs Running"   VerifyDstVmsRunning_
        JStep "${label}: Verification: Source VMIs Absent"        VerifySrcVmiGone_
        JStep "${label}: Verification: Destination PVCs Bound"    VerifyDstPvcsBound_
        JStep "${label}: Verification: Destination VM IPs Assigned" VerifyDstVmIPs_

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

# Inter-pass settle wait: gives MTV's inventory scanner time to index the newly
# arrived VM on the destination, and allows any storage/network resources created
# during Pass 1 to stabilise before Pass 2 begins.
if [[ -n "${MTV_INTER_PASS_WAIT}" && "${MTV_INTER_PASS_WAIT}" != "0" && "${MTV_INTER_PASS_WAIT}" != "0s" ]]; then
    typeset -i _waitSecs
    _waitSecs="$(ParseOcWaitDurationSeconds "${MTV_INTER_PASS_WAIT}")"
    if (( _waitSecs > 0 )); then
        : "Inter-pass settle wait: ${MTV_INTER_PASS_WAIT}"
        sleep "${_waitSecs}"
    fi
fi

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
