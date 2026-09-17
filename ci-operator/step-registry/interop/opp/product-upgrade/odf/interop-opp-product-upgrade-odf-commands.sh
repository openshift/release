#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

ODF_TARGET_CHANNEL="${ODF_TARGET_CHANNEL:-}"
ODF_UPGRADE_TIMEOUT="${ODF_UPGRADE_TIMEOUT:-45m}"
ODF_SUBSCRIPTION_NAME="${ODF_SUBSCRIPTION_NAME:-odf-operator}"
ODF_SUBSCRIPTION_NAMESPACE="${ODF_SUBSCRIPTION_NAMESPACE:-openshift-storage}"

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

function CollectDiagnostics () {
    typeset artifactFile="${ARTIFACT_DIR}/odf-upgrade-diagnostics.txt"
    {
        printf '=== ODF Operator Upgrade Diagnostics ===\n\n'
        printf '=== Subscription ===\n'
        oc get subscription "${ODF_SUBSCRIPTION_NAME}" -n "${ODF_SUBSCRIPTION_NAMESPACE}" -o yaml 2>&1 || true
        printf '\n=== CSVs in %s ===\n' "${ODF_SUBSCRIPTION_NAMESPACE}"
        oc get csv -n "${ODF_SUBSCRIPTION_NAMESPACE}" 2>&1 || true
        printf '\n=== InstallPlan ===\n'
        oc get installplan -n "${ODF_SUBSCRIPTION_NAMESPACE}" 2>&1 || true
        printf '\n=== StorageCluster ===\n'
        oc get storagecluster -n "${ODF_SUBSCRIPTION_NAMESPACE}" -o yaml 2>&1 || true
        printf '\n=== CephCluster ===\n'
        oc get cephcluster -n "${ODF_SUBSCRIPTION_NAMESPACE}" -o yaml 2>&1 || true
        printf '\n=== Pods not Ready ===\n'
        oc get pods -n "${ODF_SUBSCRIPTION_NAMESPACE}" --field-selector=status.phase!=Running,status.phase!=Succeeded 2>&1 || true
    } > "${artifactFile}"
    true
}

trap 'if (( $? != 0 )); then CollectDiagnostics; fi' EXIT

function GetCurrentCsv () {
    oc get subscription "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.currentCSV}' || true
}

function GetCsvPhase () {
    typeset csvName="$1"
    oc get csv "${csvName}" \
        -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.phase}' || true
}

function GetInstalledVersion () {
    typeset csvName
    csvName="$(GetCurrentCsv)"
    if [[ -z "${csvName}" ]]; then
        return 1
    fi
    oc get csv "${csvName}" \
        -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.version}' || true
}

function GetCurrentChannel () {
    oc get subscription "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.channel}' || true
}

function ResolveTargetChannel () {
    if [[ -n "${ODF_TARGET_CHANNEL}" ]]; then
        echo "${ODF_TARGET_CHANNEL}"
        return 0
    fi

    typeset currentChannel
    currentChannel="$(GetCurrentChannel)"
    if [[ -z "${currentChannel}" ]]; then
        echo >&2 "ERROR: Cannot determine current subscription channel"
        return 3
    fi

    typeset catalogNamespace
    catalogNamespace="$(oc get subscription "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.sourceNamespace}' || true)"

    typeset packageName
    packageName="$(oc get subscription "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.name}' || true)"

    typeset channels
    channels="$(oc get packagemanifest "${packageName}" \
        -n "${catalogNamespace}" \
        -o jsonpath='{.status.channels[*].name}' || true)"

    if [[ -z "${channels}" ]]; then
        echo >&2 "ERROR: No channels found in packagemanifest for ${packageName}"
        return 3
    fi

    typeset currentVersion nextChannel=""
    currentVersion="$(echo "${currentChannel}" | grep -oE '[0-9]+\.[0-9]+' || true)"

    typeset -a channelList
    read -ra channelList <<< "${channels}"
    for ch in "${channelList[@]}"; do
        typeset chVersion
        chVersion="$(echo "${ch}" | grep -oE '[0-9]+\.[0-9]+' || true)"
        if [[ -z "${chVersion}" ]]; then
            continue
        fi
        if [[ -z "${currentVersion}" ]]; then
            nextChannel="${ch}"
            break
        fi
        typeset currentMajor currentMinor chMajor chMinor
        currentMajor="${currentVersion%%.*}"
        currentMinor="${currentVersion##*.}"
        chMajor="${chVersion%%.*}"
        chMinor="${chVersion##*.}"

        if (( chMajor > currentMajor )) || \
           (( chMajor == currentMajor && chMinor > currentMinor )); then
            if [[ -z "${nextChannel}" ]]; then
                nextChannel="${ch}"
            else
                typeset nextVersion nextMajor nextMinor
                nextVersion="$(echo "${nextChannel}" | grep -oE '[0-9]+\.[0-9]+' || true)"
                nextMajor="${nextVersion%%.*}"
                nextMinor="${nextVersion##*.}"
                if (( chMajor < nextMajor )) || \
                   (( chMajor == nextMajor && chMinor < nextMinor )); then
                    nextChannel="${ch}"
                fi
            fi
        fi
    done

    if [[ -z "${nextChannel}" ]]; then
        echo >&2 "ERROR: No upgrade channel found newer than ${currentChannel}"
        return 3
    fi

    echo "${nextChannel}"
    true
}

function WaitForCsvSucceeded () {
    typeset previousCsv="$1"
    typeset timeoutSeconds
    timeoutSeconds="$(ParseTimeout "${ODF_UPGRADE_TIMEOUT}")"
    typeset startTime elapsed newCsv phase
    startTime="$(date +%s)"

    while true; do
        elapsed="$(( $(date +%s) - startTime ))"
        if (( elapsed > timeoutSeconds )); then
            echo >&2 "ERROR: Timeout (${ODF_UPGRADE_TIMEOUT}) waiting for CSV upgrade"
            return 2
        fi

        newCsv="$(GetCurrentCsv)"
        if [[ -z "${newCsv}" || "${newCsv}" == "${previousCsv}" ]]; then
            sleep 10
            continue
        fi

        phase="$(GetCsvPhase "${newCsv}")"
        echo "  CSV: ${newCsv}  Phase: ${phase}  (${elapsed}s elapsed)"

        case "${phase}" in
            Succeeded)
                return 0
                ;;
            Failed)
                echo >&2 "ERROR: CSV ${newCsv} entered Failed phase"
                return 1
                ;;
            *)
                sleep 15
                ;;
        esac
    done
}

function ParseTimeout () {
    typeset input="$1"
    typeset minutes=0 seconds=0
    if [[ "${input}" =~ ^([0-9]+)m$ ]]; then
        minutes="${BASH_REMATCH[1]}"
    elif [[ "${input}" =~ ^([0-9]+)s$ ]]; then
        seconds="${BASH_REMATCH[1]}"
    elif [[ "${input}" =~ ^([0-9]+)h$ ]]; then
        minutes="$(( BASH_REMATCH[1] * 60 ))"
    elif [[ "${input}" =~ ^([0-9]+)$ ]]; then
        minutes="${input}"
    else
        echo >&2 "WARNING: Unrecognized timeout format '${input}'; defaulting to 45m"
        minutes=45
    fi
    echo "$(( minutes * 60 + seconds ))"
    true
}

function ValidateSubOperatorUpgrades () {
    echo "Validating ODF sub-operator upgrades..."
    typeset -a subOperators=("ocs-operator" "mcg-operator" "noobaa-operator")

    for subOp in "${subOperators[@]}"; do
        typeset subCsv
        subCsv="$(oc get csv -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
            -l "operators.coreos.com/${subOp}.${ODF_SUBSCRIPTION_NAMESPACE}=" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

        if [[ -z "${subCsv}" ]]; then
            subCsv="$(oc get csv -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
                --no-headers 2>/dev/null | grep "^${subOp}" | awk '{print $1}' || true)"
        fi

        if [[ -z "${subCsv}" ]]; then
            echo "  WARNING: ${subOp} CSV not found; skipping"
            continue
        fi

        typeset subPhase
        subPhase="$(oc get csv "${subCsv}" -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
            -o jsonpath='{.status.phase}' || true)"
        echo "  Sub-operator ${subOp}: CSV=${subCsv} Phase=${subPhase}"

        if [[ "${subPhase}" != "Succeeded" ]]; then
            echo "  Waiting for ${subOp} CSV to reach Succeeded (timeout: 5m)..."
            typeset timeoutEnd
            timeoutEnd="$(( $(date +%s) + 300 ))"
            while (( $(date +%s) < timeoutEnd )); do
                subPhase="$(oc get csv "${subCsv}" -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
                    -o jsonpath='{.status.phase}' || true)"
                if [[ "${subPhase}" == "Succeeded" ]]; then
                    echo "  ${subOp} CSV reached Succeeded phase"
                    break
                fi
                sleep 15
            done
            if [[ "${subPhase}" != "Succeeded" ]]; then
                echo >&2 "ERROR: ${subOp} CSV did not reach Succeeded within 5 minutes"
                return 1
            fi
        fi
    done
    return 0
}

function ValidateOdfHealth () {
    echo "Validating ODF health post-upgrade..."

    typeset scPhase
    scPhase="$(oc get storagecluster -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    echo "  StorageCluster phase: ${scPhase:-not found}"

    if [[ -n "${scPhase}" && "${scPhase}" != "Ready" ]]; then
        echo "  Waiting for StorageCluster to reach Ready phase (timeout: 5m)..."
        typeset timeoutEnd
        timeoutEnd="$(( $(date +%s) + 300 ))"
        while (( $(date +%s) < timeoutEnd )); do
            scPhase="$(oc get storagecluster -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
                -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
            if [[ "${scPhase}" == "Ready" ]]; then
                echo "  StorageCluster reached Ready phase"
                break
            fi
            sleep 15
        done
        if [[ "${scPhase}" != "Ready" ]]; then
            echo >&2 "ERROR: StorageCluster did not reach Ready phase"
            return 1
        fi
    fi

    typeset cephHealth
    cephHealth="$(oc get cephcluster -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || true)"
    echo "  CephCluster health: ${cephHealth:-not found}"

    if [[ -n "${cephHealth}" && "${cephHealth}" != "HEALTH_OK" ]]; then
        echo "  Ceph health is ${cephHealth}; waiting for HEALTH_OK (timeout: 5m)..."
        typeset timeoutEnd
        timeoutEnd="$(( $(date +%s) + 300 ))"
        while (( $(date +%s) < timeoutEnd )); do
            cephHealth="$(oc get cephcluster -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
                -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || true)"
            if [[ "${cephHealth}" == "HEALTH_OK" ]]; then
                echo "  CephCluster health restored to HEALTH_OK"
                break
            fi
            sleep 15
        done
        if [[ "${cephHealth}" != "HEALTH_OK" ]]; then
            echo >&2 "WARNING: CephCluster health is ${cephHealth} (may still be rebalancing post-upgrade)"
        fi
    fi

    echo "  Checking pods in ${ODF_SUBSCRIPTION_NAMESPACE}..."
    typeset totalPods readyPods
    totalPods="$(oc get pods -n "${ODF_SUBSCRIPTION_NAMESPACE}" --no-headers 2>/dev/null | wc -l || true)"
    readyPods="$(oc get pods -n "${ODF_SUBSCRIPTION_NAMESPACE}" --no-headers \
        --field-selector=status.phase=Running 2>/dev/null | wc -l || true)"
    echo "  Pods: ${readyPods}/${totalPods} running"

    echo "ODF health validation complete"
    return 0
}

# === Main ===

function Main () {
    typeset currentCsv currentVersion currentChannel targetChannel
    typeset prePatchPlan planPhase installPlan localApproval
    typeset newCsv newVersion

    echo "=== ODF Operator Upgrade Step ==="
    echo "Namespace: ${ODF_SUBSCRIPTION_NAMESPACE}"
    echo "Subscription: ${ODF_SUBSCRIPTION_NAME}"
    echo "Timeout: ${ODF_UPGRADE_TIMEOUT}"

    currentCsv="$(GetCurrentCsv)"
    if [[ -z "${currentCsv}" ]]; then
        echo >&2 "ERROR: No ODF subscription found or no currentCSV set"
        exit 3
    fi

    currentVersion="$(GetInstalledVersion)"
    currentChannel="$(GetCurrentChannel)"
    echo "Current: CSV=${currentCsv} Version=${currentVersion} Channel=${currentChannel}"

    targetChannel="$(ResolveTargetChannel)"
    echo "Target channel: ${targetChannel}"

    prePatchPlan=""
    if ! prePatchPlan="$(oc get subscription "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null)"; then
        echo "WARNING: Could not query current installPlanRef; treating as empty"
        prePatchPlan=""
    fi
    echo "Pre-patch InstallPlan: ${prePatchPlan:-none}"

    if [[ "${targetChannel}" == "${currentChannel}" ]]; then
        echo "Already on target channel ${targetChannel}; checking if upgrade is available..."
        if [[ -z "${prePatchPlan}" ]]; then
            echo "No pending upgrade on current channel; nothing to do"
            exit 0
        fi
        planPhase="$(oc get installplan "${prePatchPlan}" \
            -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
            -o jsonpath='{.status.phase}' || true)"
        if [[ "${planPhase}" == "Complete" ]]; then
            echo "InstallPlan ${prePatchPlan} already complete; no pending upgrade"
            exit 0
        fi
        installPlan="${prePatchPlan}"
    else
        echo "Patching subscription channel: ${currentChannel} -> ${targetChannel}"
        oc patch subscription "${ODF_SUBSCRIPTION_NAME}" \
            -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
            --type merge \
            -p "{\"spec\":{\"channel\":\"${targetChannel}\"}}"

        echo "Waiting for new InstallPlan (pre-patch ref: ${prePatchPlan:-none})..."
        sleep 10

        installPlan=""
        for _ in {1..18}; do
            installPlan="$(oc get subscription "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
                -o jsonpath='{.status.installPlanRef.name}' || true)"
            if [[ -n "${installPlan}" && "${installPlan}" != "${prePatchPlan}" ]]; then
                break
            fi
            installPlan=""
            sleep 10
        done

        if [[ -z "${installPlan}" ]]; then
            echo >&2 "ERROR: No new InstallPlan appeared after channel change (waited 3m)"
            exit 2
        fi
    fi

    echo "InstallPlan: ${installPlan}"
    localApproval="$(oc get installplan "${installPlan}" \
        -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.approval}' || true)"
    if [[ "${localApproval}" == "Manual" ]]; then
        echo "Approving manual InstallPlan..."
        oc patch installplan "${installPlan}" \
            -n "${ODF_SUBSCRIPTION_NAMESPACE}" \
            --type merge \
            -p '{"spec":{"approved":true}}'
    fi

    echo "Waiting for ODF CSV to reach Succeeded phase..."
    WaitForCsvSucceeded "${currentCsv}"
    newCsv="$(GetCurrentCsv)"
    newVersion="$(GetInstalledVersion)"
    echo "Upgrade complete: ${currentVersion} -> ${newVersion} (CSV: ${newCsv})"

    ValidateSubOperatorUpgrades
    ValidateOdfHealth

    {
        printf '=== ODF Operator Upgrade Summary ===\n'
        printf 'Previous: %s (%s)\n' "${currentVersion}" "${currentChannel}"
        printf 'Current:  %s (%s)\n' "${newVersion}" "${targetChannel}"
        printf 'CSV:      %s\n' "${newCsv}"
        printf 'Status:   SUCCESS\n'
    } > "${ARTIFACT_DIR}/odf-upgrade-summary.txt"

    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "${newVersion}" > "${SHARED_DIR}/odf-upgraded-version"
        echo "${targetChannel}" > "${SHARED_DIR}/odf-upgraded-channel"
    fi

    echo "=== ODF Operator Upgrade: SUCCESS ==="
    true
}

Main "$@"
