#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

ACM_TARGET_CHANNEL="${ACM_TARGET_CHANNEL:-}"
ACM_UPGRADE_TIMEOUT="${ACM_UPGRADE_TIMEOUT:-30m}"
ACM_SUBSCRIPTION_NAME="${ACM_SUBSCRIPTION_NAME:-advanced-cluster-management}"
ACM_SUBSCRIPTION_NAMESPACE="${ACM_SUBSCRIPTION_NAMESPACE:-open-cluster-management}"

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

function CollectDiagnostics () {
    typeset artifactFile="${ARTIFACT_DIR}/acm-upgrade-diagnostics.txt"
    {
        printf '=== ACM Operator Upgrade Diagnostics ===\n\n'
        printf '=== Subscription ===\n'
        oc get subscription "${ACM_SUBSCRIPTION_NAME}" -n "${ACM_SUBSCRIPTION_NAMESPACE}" -o yaml 2>&1 || true
        printf '\n=== CSVs in %s ===\n' "${ACM_SUBSCRIPTION_NAMESPACE}"
        oc get csv -n "${ACM_SUBSCRIPTION_NAMESPACE}" 2>&1 || true
        printf '\n=== InstallPlan ===\n'
        oc get installplan -n "${ACM_SUBSCRIPTION_NAMESPACE}" 2>&1 || true
        printf '\n=== MCE CSVs ===\n'
        oc get csv -n multicluster-engine 2>&1 || true
        printf '\n=== Pods not Ready ===\n'
        oc get pods -n "${ACM_SUBSCRIPTION_NAMESPACE}" --field-selector=status.phase!=Running,status.phase!=Succeeded 2>&1 || true
        oc get pods -n multicluster-engine --field-selector=status.phase!=Running,status.phase!=Succeeded 2>&1 || true
    } > "${artifactFile}"
    true
}

trap 'if (( $? != 0 )); then CollectDiagnostics; fi' EXIT

function GetCurrentCsv () {
    oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.currentCSV}' || true
}

function GetCsvPhase () {
    typeset csvName="$1"
    oc get csv "${csvName}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.phase}' || true
}

function GetInstalledVersion () {
    typeset csvName
    csvName="$(GetCurrentCsv)"
    if [[ -z "${csvName}" ]]; then
        return 1
    fi
    oc get csv "${csvName}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.version}' || true
}

function GetCurrentChannel () {
    oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.channel}' || true
}

function ResolveTargetChannel () {
    if [[ -n "${ACM_TARGET_CHANNEL}" ]]; then
        echo "${ACM_TARGET_CHANNEL}"
        return 0
    fi

    typeset currentChannel
    currentChannel="$(GetCurrentChannel)"
    if [[ -z "${currentChannel}" ]]; then
        echo >&2 "ERROR: Cannot determine current subscription channel"
        return 3
    fi

    typeset catalogNamespace
    catalogNamespace="$(oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.sourceNamespace}' || true)"

    typeset packageName
    packageName="$(oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
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
    timeoutSeconds="$(ParseTimeout "${ACM_UPGRADE_TIMEOUT}")"
    typeset startTime elapsed newCsv phase
    startTime="$(date +%s)"

    while true; do
        elapsed="$(( $(date +%s) - startTime ))"
        if (( elapsed > timeoutSeconds )); then
            echo >&2 "ERROR: Timeout (${ACM_UPGRADE_TIMEOUT}) waiting for CSV upgrade"
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
        echo >&2 "WARNING: Unrecognized timeout format '${input}'; defaulting to 30m"
        minutes=30
    fi
    echo "$(( minutes * 60 + seconds ))"
    true
}

function ValidateMceUpgrade () {
    echo "Validating MCE (MultiCluster Engine) upgrade..."
    typeset mceCsv
    mceCsv="$(oc get csv -n multicluster-engine \
        -o jsonpath='{.items[?(@.spec.displayName=="multicluster engine for Kubernetes")].metadata.name}' \
        || true)"

    if [[ -z "${mceCsv}" ]]; then
        mceCsv="$(oc get csv -n multicluster-engine \
            -l operators.coreos.com/multicluster-engine.multicluster-engine= \
            -o jsonpath='{.items[0].metadata.name}' || true)"
    fi

    if [[ -z "${mceCsv}" ]]; then
        echo "WARNING: MCE CSV not found; skipping MCE validation"
        return 0
    fi

    typeset mcePhase
    mcePhase="$(oc get csv "${mceCsv}" -n multicluster-engine \
        -o jsonpath='{.status.phase}' || true)"

    echo "  MCE CSV: ${mceCsv}  Phase: ${mcePhase}"
    if [[ "${mcePhase}" != "Succeeded" ]]; then
        echo "WARNING: MCE CSV phase is ${mcePhase}, not Succeeded"
        typeset timeoutEnd
        timeoutEnd="$(( $(date +%s) + 300 ))"
        while (( $(date +%s) < timeoutEnd )); do
            mcePhase="$(oc get csv "${mceCsv}" -n multicluster-engine \
                -o jsonpath='{.status.phase}' || true)"
            if [[ "${mcePhase}" == "Succeeded" ]]; then
                echo "  MCE CSV reached Succeeded phase"
                return 0
            fi
            sleep 15
        done
        echo >&2 "ERROR: MCE CSV did not reach Succeeded within 5 minutes"
        return 1
    fi
    return 0
}

function ValidateHubHealth () {
    echo "Validating ACM hub health post-upgrade..."

    typeset mchStatus
    mchStatus="$(oc get multiclusterhub -A \
        -o jsonpath='{.items[0].status.phase}' || true)"
    echo "  MultiClusterHub phase: ${mchStatus}"

    if [[ "${mchStatus}" != "Running" ]]; then
        echo "  Waiting for MCH to reach Running phase (timeout: 5m)..."
        typeset timeoutEnd
        timeoutEnd="$(( $(date +%s) + 300 ))"
        while (( $(date +%s) < timeoutEnd )); do
            mchStatus="$(oc get multiclusterhub -A \
                -o jsonpath='{.items[0].status.phase}' || true)"
            if [[ "${mchStatus}" == "Running" ]]; then
                break
            fi
            sleep 15
        done
        if [[ "${mchStatus}" != "Running" ]]; then
            echo >&2 "ERROR: MultiClusterHub did not reach Running phase"
            return 1
        fi
    fi

    echo "  Checking policy propagator..."
    typeset propagatorReady=""
    typeset -i propTimeout=300
    typeset -i propStart
    propStart="$(date +%s)"
    while (( $(date +%s) - propStart < propTimeout )); do
        propagatorReady="$(oc get pods -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
            -l name=governance-policy-propagator \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' \
            || true)"
        if [[ "${propagatorReady}" == "True" ]]; then
            break
        fi
        sleep 15
    done
    echo "  Policy propagator ready: ${propagatorReady}"
    if [[ "${propagatorReady}" != "True" ]]; then
        echo >&2 "ERROR: Policy propagator not ready after ${propTimeout}s"
        return 1
    fi

    echo "  Checking managed clusters..."
    typeset clusterOutput=""
    clusterOutput="$(oc get managedclusters --no-headers || true)"
    typeset -i clusterCount=0
    clusterCount="$(echo "${clusterOutput}" | grep -c . || true)"
    typeset availableOutput=""
    availableOutput="$(oc get managedclusters \
        -o jsonpath='{.items[?(@.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status=="True")].metadata.name}' \
        || true)"
    typeset -i availableCount=0
    availableCount="$(echo "${availableOutput}" | wc -w)"
    echo "  Managed clusters: ${availableCount}/${clusterCount} available"

    if (( clusterCount > 0 && availableCount == 0 )); then
        echo >&2 "WARNING: All ${clusterCount} managed cluster(s) are unavailable after upgrade"
    elif (( clusterCount > 0 && availableCount < clusterCount )); then
        echo >&2 "WARNING: ${availableCount}/${clusterCount} managed cluster(s) available (some may be reconciling post-upgrade)"
    fi

    echo "ACM hub health validation complete"
    return 0
}

# === Main ===

echo "=== ACM Operator Upgrade Step ==="
echo "Namespace: ${ACM_SUBSCRIPTION_NAMESPACE}"
echo "Subscription: ${ACM_SUBSCRIPTION_NAME}"
echo "Timeout: ${ACM_UPGRADE_TIMEOUT}"

currentCsv="$(GetCurrentCsv)"
if [[ -z "${currentCsv}" ]]; then
    echo >&2 "ERROR: No ACM subscription found or no currentCSV set"
    exit 3
fi

currentVersion="$(GetInstalledVersion)"
currentChannel="$(GetCurrentChannel)"
echo "Current: CSV=${currentCsv} Version=${currentVersion} Channel=${currentChannel}"

targetChannel="$(ResolveTargetChannel)"
echo "Target channel: ${targetChannel}"

prePatchPlan=""
if ! prePatchPlan="$(oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
    -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
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
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.phase}' || true)"
    if [[ "${planPhase}" == "Complete" ]]; then
        echo "InstallPlan ${prePatchPlan} already complete; no pending upgrade"
        exit 0
    fi
    installPlan="${prePatchPlan}"
else
    echo "Patching subscription channel: ${currentChannel} -> ${targetChannel}"
    oc patch subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        --type merge \
        -p "{\"spec\":{\"channel\":\"${targetChannel}\"}}"

    echo "Waiting for new InstallPlan (pre-patch ref: ${prePatchPlan:-none})..."
    sleep 10

    installPlan=""
    for _ in {1..18}; do
        installPlan="$(oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
            -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
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
    -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
    -o jsonpath='{.spec.approval}' || true)"
if [[ "${localApproval}" == "Manual" ]]; then
    echo "Approving manual InstallPlan..."
    oc patch installplan "${installPlan}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        --type merge \
        -p '{"spec":{"approved":true}}'
fi

echo "Waiting for ACM CSV to reach Succeeded phase..."
WaitForCsvSucceeded "${currentCsv}"
newCsv="$(GetCurrentCsv)"
newVersion="$(GetInstalledVersion)"
echo "Upgrade complete: ${currentVersion} -> ${newVersion} (CSV: ${newCsv})"

ValidateMceUpgrade
ValidateHubHealth

{
    printf '=== ACM Operator Upgrade Summary ===\n'
    printf 'Previous: %s (%s)\n' "${currentVersion}" "${currentChannel}"
    printf 'Current:  %s (%s)\n' "${newVersion}" "${targetChannel}"
    printf 'CSV:      %s\n' "${newCsv}"
    printf 'Status:   SUCCESS\n'
} > "${ARTIFACT_DIR}/acm-upgrade-summary.txt"

if [[ -n "${SHARED_DIR:-}" ]]; then
    echo "${newVersion}" > "${SHARED_DIR}/acm-upgraded-version"
    echo "${targetChannel}" > "${SHARED_DIR}/acm-upgraded-channel"
fi

echo "=== ACM Operator Upgrade: SUCCESS ==="
true
