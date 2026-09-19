#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

QUAY_TARGET_CHANNEL="${QUAY_TARGET_CHANNEL:-}"
QUAY_UPGRADE_TIMEOUT="${QUAY_UPGRADE_TIMEOUT:-30m}"
QUAY_SUBSCRIPTION_NAME="${QUAY_SUBSCRIPTION_NAME:-quay-operator}"
QUAY_SUBSCRIPTION_NAMESPACE="${QUAY_SUBSCRIPTION_NAMESPACE:-openshift-operators}"

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

function CollectDiagnostics () {
    typeset artifactFile="${ARTIFACT_DIR}/quay-upgrade-diagnostics.txt"
    {
        printf '=== Quay Operator Upgrade Diagnostics ===\n\n'
        printf '=== Subscription ===\n'
        oc get subscription "${QUAY_SUBSCRIPTION_NAME}" -n "${QUAY_SUBSCRIPTION_NAMESPACE}" -o yaml 2>&1 || true
        printf '\n=== CSVs in %s ===\n' "${QUAY_SUBSCRIPTION_NAMESPACE}"
        oc get csv -n "${QUAY_SUBSCRIPTION_NAMESPACE}" 2>&1 || true
        printf '\n=== InstallPlan ===\n'
        oc get installplan -n "${QUAY_SUBSCRIPTION_NAMESPACE}" 2>&1 || true
        printf '\n=== QuayRegistry Instances ===\n'
        oc get quayregistry -A 2>&1 || true
        printf '\n=== QuayRegistry Details ===\n'
        oc get quayregistry -A -o yaml 2>&1 || true
        printf '\n=== Pods not Ready ===\n'
        oc get pods -n "${QUAY_SUBSCRIPTION_NAMESPACE}" --field-selector=status.phase!=Running,status.phase!=Succeeded 2>&1 || true
    } > "${artifactFile}"
    true
}

trap 'if (( $? != 0 )); then CollectDiagnostics; fi' EXIT

function GetCurrentCsv () {
    oc get subscription "${QUAY_SUBSCRIPTION_NAME}" \
        -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.currentCSV}' || true
}

function GetCsvPhase () {
    typeset csvName="$1"
    oc get csv "${csvName}" \
        -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.phase}' || true
}

function GetInstalledVersion () {
    typeset csvName
    csvName="$(GetCurrentCsv)"
    if [[ -z "${csvName}" ]]; then
        return 1
    fi
    oc get csv "${csvName}" \
        -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.version}' || true
}

function GetCurrentChannel () {
    oc get subscription "${QUAY_SUBSCRIPTION_NAME}" \
        -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.channel}' || true
}

function ResolveTargetChannel () {
    if [[ -n "${QUAY_TARGET_CHANNEL}" ]]; then
        echo "${QUAY_TARGET_CHANNEL}"
        return 0
    fi

    typeset currentChannel
    currentChannel="$(GetCurrentChannel)"
    if [[ -z "${currentChannel}" ]]; then
        echo >&2 "ERROR: Cannot determine current subscription channel"
        return 3
    fi

    typeset catalogNamespace
    catalogNamespace="$(oc get subscription "${QUAY_SUBSCRIPTION_NAME}" \
        -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.sourceNamespace}' || true)"

    typeset packageName
    packageName="$(oc get subscription "${QUAY_SUBSCRIPTION_NAME}" \
        -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
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
    timeoutSeconds="$(ParseTimeout "${QUAY_UPGRADE_TIMEOUT}")"
    typeset startTime elapsed newCsv phase
    startTime="$(date +%s)"

    while true; do
        elapsed="$(( $(date +%s) - startTime ))"
        if (( elapsed > timeoutSeconds )); then
            echo >&2 "ERROR: Timeout (${QUAY_UPGRADE_TIMEOUT}) waiting for CSV upgrade"
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

function ValidateQuayHealth () {
    echo "Validating Quay health post-upgrade..."

    typeset quayNs
    quayNs="$(oc get quayregistry -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"

    if [[ -z "${quayNs}" ]]; then
        echo "WARNING: No QuayRegistry CR found; skipping QuayRegistry validation"
        return 0
    fi

    typeset quayAvailable
    quayAvailable="$(oc get quayregistry -n "${quayNs}" \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    echo "  QuayRegistry Available: ${quayAvailable:-unknown}"

    if [[ "${quayAvailable}" != "True" ]]; then
        echo "  Waiting for QuayRegistry to reach Available condition (timeout: 5m)..."
        typeset timeoutEnd
        timeoutEnd="$(( $(date +%s) + 300 ))"
        while (( $(date +%s) < timeoutEnd )); do
            quayAvailable="$(oc get quayregistry -n "${quayNs}" \
                -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
            if [[ "${quayAvailable}" == "True" ]]; then
                echo "  QuayRegistry reached Available condition"
                break
            fi
            sleep 15
        done
        if [[ "${quayAvailable}" != "True" ]]; then
            echo >&2 "ERROR: QuayRegistry did not reach Available condition within 5 minutes"
            return 1
        fi
    fi

    echo "  Checking key Quay deployments..."
    for deploy in quay-operator quay-app quay-database quay-redis clair-app; do
        typeset available
        available="$(oc get deployment "${deploy}" -n "${quayNs}" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
        if [[ -z "${available}" ]]; then
            typeset quayRegistryName
            quayRegistryName="$(oc get quayregistry -n "${quayNs}" \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
            if [[ -n "${quayRegistryName}" ]]; then
                available="$(oc get deployment "${quayRegistryName}-${deploy}" -n "${quayNs}" \
                    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
                if [[ -n "${available}" ]]; then
                    deploy="${quayRegistryName}-${deploy}"
                fi
            fi
        fi
        echo "  Deployment ${deploy}: Available=${available:-not found}"
        if [[ -n "${available}" && "${available}" != "True" ]]; then
            echo >&2 "WARNING: Deployment ${deploy} is not Available"
        fi
    done

    echo "Quay health validation complete"
    return 0
}

# === Main ===

function Main () {
    typeset currentCsv currentVersion currentChannel targetChannel
    typeset prePatchPlan planPhase installPlan localApproval
    typeset newCsv newVersion

    echo "=== Quay Operator Upgrade Step ==="
    echo "Namespace: ${QUAY_SUBSCRIPTION_NAMESPACE}"
    echo "Subscription: ${QUAY_SUBSCRIPTION_NAME}"
    echo "Timeout: ${QUAY_UPGRADE_TIMEOUT}"

    currentCsv="$(GetCurrentCsv)"
    if [[ -z "${currentCsv}" ]]; then
        echo >&2 "ERROR: No Quay subscription found or no currentCSV set"
        exit 3
    fi

    currentVersion="$(GetInstalledVersion)"
    currentChannel="$(GetCurrentChannel)"
    echo "Current: CSV=${currentCsv} Version=${currentVersion} Channel=${currentChannel}"

    targetChannel="$(ResolveTargetChannel)"
    echo "Target channel: ${targetChannel}"

    prePatchPlan=""
    if ! prePatchPlan="$(oc get subscription "${QUAY_SUBSCRIPTION_NAME}" \
        -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
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
            -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
            -o jsonpath='{.status.phase}' || true)"
        if [[ "${planPhase}" == "Complete" ]]; then
            echo "InstallPlan ${prePatchPlan} already complete; no pending upgrade"
            exit 0
        fi
        installPlan="${prePatchPlan}"
    else
        echo "Patching subscription channel: ${currentChannel} -> ${targetChannel}"
        oc patch subscription "${QUAY_SUBSCRIPTION_NAME}" \
            -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
            --type merge \
            -p "{\"spec\":{\"channel\":\"${targetChannel}\"}}"

        echo "Waiting for new InstallPlan (pre-patch ref: ${prePatchPlan:-none})..."
        sleep 10

        installPlan=""
        for _ in {1..18}; do
            installPlan="$(oc get subscription "${QUAY_SUBSCRIPTION_NAME}" \
                -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
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
        -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.approval}' || true)"
    if [[ "${localApproval}" == "Manual" ]]; then
        echo "Approving manual InstallPlan..."
        oc patch installplan "${installPlan}" \
            -n "${QUAY_SUBSCRIPTION_NAMESPACE}" \
            --type merge \
            -p '{"spec":{"approved":true}}'
    fi

    echo "Waiting for Quay CSV to reach Succeeded phase..."
    WaitForCsvSucceeded "${currentCsv}"
    newCsv="$(GetCurrentCsv)"
    newVersion="$(GetInstalledVersion)"
    echo "Upgrade complete: ${currentVersion} -> ${newVersion} (CSV: ${newCsv})"

    ValidateQuayHealth

    {
        printf '=== Quay Operator Upgrade Summary ===\n'
        printf 'Previous: %s (%s)\n' "${currentVersion}" "${currentChannel}"
        printf 'Current:  %s (%s)\n' "${newVersion}" "${targetChannel}"
        printf 'CSV:      %s\n' "${newCsv}"
        printf 'Status:   SUCCESS\n'
    } > "${ARTIFACT_DIR}/quay-upgrade-summary.txt"

    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "${newVersion}" > "${SHARED_DIR}/quay-upgraded-version"
        echo "${targetChannel}" > "${SHARED_DIR}/quay-upgraded-channel"
    fi

    echo "=== Quay Operator Upgrade: SUCCESS ==="
    true
}

Main "$@"
