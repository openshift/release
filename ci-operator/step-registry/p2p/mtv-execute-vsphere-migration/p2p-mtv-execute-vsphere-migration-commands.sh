#!/bin/bash
#
# Execute MTV cold migration from VMware vSphere to OpenShift Virtualization (CI step).
#
# Creates a Forklift Plan referencing vSphere VMs by MoRef ID, creates a Migration
# object, polls until Succeeded, then verifies the migrated VMs appear on the destination
# spoke as KubeVirt VirtualMachines.
#
# Different from p2p-mtv-execute-live-migration (OCP-to-OCP CCLM):
#   - No source spoke kubeconfig: vSphere VMs are referenced by MoRef ID, not OCP object.
#   - Uses govc to resolve VM IDs from names in SHARED_DIR/vsphere-vm-names.
#   - Only the destination spoke kubeconfig is needed (to verify migrated VMs).
#   - Plan type is "cold" (vSphere warm migration is a separate concern).
#
# Inputs from SHARED_DIR:
#   vsphere-vm-names                    — newline-separated VM names (from p2p-create-vsphere-test-vms)
#   managed-cluster-kubeconfig-{N}      — destination spoke admin kubeconfig
#
# Hub kubeconfig is KUBECONFIG from ci-operator.
#

set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq govc

typeset -r VSPHERE_ENV_SCRIPT=/var/run/vault/vsphere-ibmcloud-config/load-vsphere-env-config.sh

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# =====================
# Input validation
# =====================
[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]
[[ -f "${SHARED_DIR}/vsphere-vm-names" ]]
[[ -f "${SHARED_DIR}/vsphere-vcenter-host" ]]
[[ -f "${VSPHERE_ENV_SCRIPT}" ]]

typeset -i destSpokeIndex="${P2P_MTV_VSPHERE_DEST_SPOKE_INDEX}"
typeset destKubeconfig
destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}"
[[ -r "${destKubeconfig}" ]]

# Temp file for JUnit records
typeset -r junitFile="${TMPDIR:-/tmp}/vsphere-mig-junit-$$.tsv"
typeset -i migRc=0

# =====================
# Load vSphere env config (for govc credentials)
# =====================
# shellcheck disable=SC1090
source "${VSPHERE_ENV_SCRIPT}"
[[ -n "${VCENTER_AUTH_PATH:-}" ]]
[[ -f "${VCENTER_AUTH_PATH}" ]]

typeset vcenterHost
vcenterHost="$(< "${SHARED_DIR}/vsphere-vcenter-host")"
[[ -n "${vcenterHost}" ]]

# Set govc environment (credentials — disable xtrace)
set +x
export GOVC_URL="https://${vcenterHost}/sdk"
export GOVC_USERNAME
export GOVC_PASSWORD
GOVC_USERNAME="$(< "${VCENTER_AUTH_PATH}")"
GOVC_PASSWORD="${GOVC_USERNAME#*:}"
GOVC_USERNAME="${GOVC_USERNAME%%:*}"
export GOVC_INSECURE=1
set -x

# =====================
# Resolve VM MoRef IDs from names
# =====================
typeset -a vmNames=()
typeset -a vmMoRefs=()
typeset vmName vmId

while IFS= read -r vmName; do
    [[ -n "${vmName}" ]] || continue
    vmNames+=("${vmName}")
    vmId="$(
        govc vm.info -json "${vmName}" 2>/dev/null |
        jq -r '.VirtualMachines[0].Self.Value // empty'
    )"
    if [[ -z "${vmId}" ]]; then
        : "ERROR: Could not resolve MoRef ID for VM ${vmName}"
        exit 1
    fi
    vmMoRefs+=("${vmId}")
    : "VM ${vmName} → MoRef ${vmId}"
done < "${SHARED_DIR}/vsphere-vm-names"

(( ${#vmNames[@]} > 0 ))

# =====================
# Helper functions
# =====================
HubOc() { oc --kubeconfig="${KUBECONFIG}" "$@"; }
DestOc() { oc --kubeconfig="${destKubeconfig}" "$@"; }

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

# =====================
# Build Plan VMs array using jq (MoRef IDs, no namespace for vSphere source)
# =====================
BuildVmList() {
    typeset -i i
    typeset vmArr="[]"

    for (( i = 0; i < ${#vmNames[@]}; i++ )); do
        vmArr="$(
            jq -n \
                --argjson arr "${vmArr}" \
                --arg name "${vmNames[i]}" \
                --arg id   "${vmMoRefs[i]}" \
                '$arr + [{name: $name, id: $id}]'
        )"
    done
    printf '%s' "${vmArr}"
}

# =====================
# Apply Plan
# =====================
ApplyPlan() {
    typeset vmListJson
    vmListJson="$(BuildVmList)"

    jq -n \
        --arg planName  "${P2P_MTV_VSPHERE_PLAN_NAME}" \
        --arg ns        "${MTV_NAMESPACE}" \
        --arg srcProv   "${P2P_MTV_VSPHERE_SOURCE_PROVIDER}" \
        --arg dstProv   "${P2P_MTV_VSPHERE_DEST_PROVIDER}" \
        --arg targetNs  "${P2P_MTV_VSPHERE_TARGET_NAMESPACE}" \
        --arg netMap    "${P2P_MTV_VSPHERE_NETWORK_MAP_NAME}" \
        --arg stoMap    "${P2P_MTV_VSPHERE_STORAGE_MAP_NAME}" \
        --argjson vms   "${vmListJson}" \
        '{
            apiVersion: "forklift.konveyor.io/v1beta1",
            kind: "Plan",
            metadata: {name: $planName, namespace: $ns},
            spec: {
                provider: {
                    source:      {name: $srcProv, namespace: $ns},
                    destination: {name: $dstProv, namespace: $ns}
                },
                targetNamespace: $targetNs,
                map: {
                    network: {name: $netMap, namespace: $ns},
                    storage: {name: $stoMap, namespace: $ns}
                },
                vms: $vms,
                type: "cold"
            }
        }' | {
        HubOc create -f - --dry-run=client -o yaml --save-config
    } | HubOc apply -f -
}

# =====================
# Wait for Plan Ready
# =====================
WaitPlanReady() {
    HubOc wait "plan/${P2P_MTV_VSPHERE_PLAN_NAME}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${P2P_MTV_VSPHERE_PLAN_READY_TIMEOUT}"
}

# =====================
# Apply Migration
# =====================
ApplyMigration() {
    jq -n \
        --arg migName  "${P2P_MTV_VSPHERE_MIGRATION_NAME}" \
        --arg ns       "${MTV_NAMESPACE}" \
        --arg planName "${P2P_MTV_VSPHERE_PLAN_NAME}" \
        '{
            apiVersion: "forklift.konveyor.io/v1beta1",
            kind: "Migration",
            metadata: {name: $migName, namespace: $ns},
            spec: {
                plan: {name: $planName, namespace: $ns}
            }
        }' | {
        HubOc create -f - --dry-run=client -o yaml --save-config
    } | HubOc apply -f -
}

# =====================
# Poll until Migration Succeeded or Failed
# =====================
WaitMigrationSucceeded() {
    typeset -i deadline
    typeset succeeded failed

    deadline=$(( SECONDS + P2P_MTV_VSPHERE_MIGRATION_TIMEOUT_SECONDS ))

    while (( SECONDS < deadline )); do
        succeeded="$(HubOc get "migration/${P2P_MTV_VSPHERE_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' || true)"
        failed="$(HubOc get "migration/${P2P_MTV_VSPHERE_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)"

        [[ "${succeeded}" == "True" ]] && return 0

        if [[ "${failed}" == "True" ]]; then
            HubOc get "migration/${P2P_MTV_VSPHERE_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' 1>&2 || true
            false
        fi

        : "Migration in progress (${SECONDS}/${deadline}s)"
        sleep "${P2P_MTV_VSPHERE_MIGRATION_POLL_SECONDS}"
    done

    : "ERROR: Migration timed out after ${P2P_MTV_VSPHERE_MIGRATION_TIMEOUT_SECONDS}s"
    false
}

# =====================
# Verify migrated VMs exist on destination spoke
# =====================
VerifyMigratedVMs() {
    typeset vm
    for vm in "${vmNames[@]}"; do
        DestOc get "virtualmachine/${vm}" -n "${P2P_MTV_VSPHERE_TARGET_NAMESPACE}" 1>/dev/null
        : "VM ${vm} verified on destination spoke"
    done
}

# =====================
# Dump diagnostics on failure
# =====================
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/mtv-vsphere-migration-diagnostics"
    mkdir -p "${diagDir}"

    HubOc get plan,migration,networkmap,storagemap,provider -n "${MTV_NAMESPACE}" \
        > "${diagDir}/hub-mtv-resources.txt" 2>&1 || true
    HubOc describe "plan/${P2P_MTV_VSPHERE_PLAN_NAME}" -n "${MTV_NAMESPACE}" \
        > "${diagDir}/plan-describe.txt" 2>&1 || true
    HubOc describe "migration/${P2P_MTV_VSPHERE_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
        > "${diagDir}/migration-describe.txt" 2>&1 || true
    HubOc get events -n "${MTV_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${diagDir}/hub-mtv-events.txt" 2>&1 || true
    DestOc get virtualmachine,datavolume,pvc -n "${P2P_MTV_VSPHERE_TARGET_NAMESPACE}" \
        > "${diagDir}/dest-vms.txt" 2>&1 || true
}

# =====================
# Write JUnit XML
# =====================
XmlEscape() {
    typeset s="${1}"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
    s="${s//\"/&quot;}"; s="${s//\'/&apos;}"
    printf '%s' "${s}"
}

WriteJunit() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    [[ -f "${junitFile}" ]] || return 0

    typeset xmlFile="${ARTIFACT_DIR}/junit_vsphere_migration.xml"
    typeset -i total=0 failures=0 totalTime=0
    typeset status name elapsed failMsg

    while IFS=$'\t' read -r status name elapsed failMsg; do
        (( total++ )) || true
        (( totalTime += elapsed )) || true
        [[ "${status}" == "FAIL" ]] && (( failures++ )) || true
    done < "${junitFile}"

    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuite name="vsphere-migration" tests="%d" failures="%d" errors="0" skipped="0" time="%d">\n' \
            "${total}" "${failures}" "${totalTime}"
        while IFS=$'\t' read -r status name elapsed failMsg; do
            printf '  <testcase name="%s" classname="vsphere-migration" time="%d">\n' \
                "$(XmlEscape "${name}")" "${elapsed}"
            if [[ "${status}" == "FAIL" ]]; then
                printf '    <failure message="%s">%s</failure>\n' \
                    "$(XmlEscape "${failMsg}")" "$(XmlEscape "${failMsg}")"
            fi
            printf '  </testcase>\n'
        done < "${junitFile}"
        printf '</testsuite>\n'
    } > "${xmlFile}"

    : "JUnit XML written → ${xmlFile} (${total} tests, ${failures} failures)"
    rm -f "${junitFile}"
}

# =====================
# Main
# =====================
trap - ERR

(
    trap 'typeset -i _ec=$?; DumpDiagnostics; exit ${_ec}' ERR

    HubOc get ns "${MTV_NAMESPACE}" 1>/dev/null

    JStep "Apply Plan (vSphere→OCP cold migration)"  ApplyPlan
    JStep "Wait Plan Ready"                           WaitPlanReady
    JStep "Apply Migration"                           ApplyMigration
    JStep "Wait Migration Succeeded"                  WaitMigrationSucceeded
    JStep "Verify VMs on Destination Spoke"           VerifyMigratedVMs

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            HubOc get "plan/${P2P_MTV_VSPHERE_PLAN_NAME}" \
                      "migration/${P2P_MTV_VSPHERE_MIGRATION_NAME}" \
                      -n "${MTV_NAMESPACE}" -o wide
            HubOc get "migration/${P2P_MTV_VSPHERE_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
        } > "${ARTIFACT_DIR}/mtv-vsphere-migration-status.txt"
    fi
    true
) || migRc=$?

WriteJunit

if (( migRc != 0 )); then
    DumpDiagnostics
    exit "${migRc}"
fi

true
