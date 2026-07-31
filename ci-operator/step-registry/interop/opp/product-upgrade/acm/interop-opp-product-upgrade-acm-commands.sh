#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit

ACM_TARGET_CHANNEL="${ACM_TARGET_CHANNEL:-}"
ACM_UPGRADE_TIMEOUT="${ACM_UPGRADE_TIMEOUT:-30m}"
ACM_SUBSCRIPTION_NAME="${ACM_SUBSCRIPTION_NAME:-advanced-cluster-management}"
ACM_SUBSCRIPTION_NAMESPACE="${ACM_SUBSCRIPTION_NAMESPACE:-open-cluster-management}"

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

# shellcheck disable=SC2034
typeset -i exit_code=0

collect_diagnostics() {
    local artifact_file="${ARTIFACT_DIR}/acm-upgrade-diagnostics.txt"
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
    } > "${artifact_file}"
}

trap 'exit_code=$?; if (( exit_code != 0 )); then collect_diagnostics; fi' EXIT

get_current_csv() {
    oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.currentCSV}' 2>/dev/null || true
}

get_csv_phase() {
    local csv_name="$1"
    oc get csv "${csv_name}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true
}

get_installed_version() {
    local csv_name
    csv_name="$(get_current_csv)"
    if [[ -z "${csv_name}" ]]; then
        return 1
    fi
    oc get csv "${csv_name}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.version}' 2>/dev/null || true
}

get_current_channel() {
    oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.channel}' 2>/dev/null || true
}

resolve_target_channel() {
    if [[ -n "${ACM_TARGET_CHANNEL}" ]]; then
        echo "${ACM_TARGET_CHANNEL}"
        return 0
    fi

    local current_channel
    current_channel="$(get_current_channel)"
    if [[ -z "${current_channel}" ]]; then
        echo >&2 "ERROR: Cannot determine current subscription channel"
        return 3
    fi

    local catalog_namespace
    catalog_namespace="$(oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.sourceNamespace}' 2>/dev/null || true)"

    local package_name
    package_name="$(oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.name}' 2>/dev/null || true)"

    local channels
    channels="$(oc get packagemanifest "${package_name}" \
        -n "${catalog_namespace}" \
        -o jsonpath='{.status.channels[*].name}' 2>/dev/null || true)"

    if [[ -z "${channels}" ]]; then
        echo >&2 "ERROR: No channels found in packagemanifest for ${package_name}"
        return 3
    fi

    local current_version next_channel=""
    current_version="$(echo "${current_channel}" | grep -oE '[0-9]+\.[0-9]+' || true)"

    for ch in ${channels}; do
        local ch_version
        ch_version="$(echo "${ch}" | grep -oE '[0-9]+\.[0-9]+' || true)"
        if [[ -z "${ch_version}" ]]; then
            continue
        fi
        if [[ -z "${current_version}" ]]; then
            next_channel="${ch}"
            break
        fi
        local current_major current_minor ch_major ch_minor
        current_major="${current_version%%.*}"
        current_minor="${current_version##*.}"
        ch_major="${ch_version%%.*}"
        ch_minor="${ch_version##*.}"

        if (( ch_major > current_major )) || \
           (( ch_major == current_major && ch_minor > current_minor )); then
            if [[ -z "${next_channel}" ]]; then
                next_channel="${ch}"
            else
                local next_version next_major next_minor
                next_version="$(echo "${next_channel}" | grep -oE '[0-9]+\.[0-9]+' || true)"
                next_major="${next_version%%.*}"
                next_minor="${next_version##*.}"
                if (( ch_major < next_major )) || \
                   (( ch_major == next_major && ch_minor < next_minor )); then
                    next_channel="${ch}"
                fi
            fi
        fi
    done

    if [[ -z "${next_channel}" ]]; then
        echo >&2 "ERROR: No upgrade channel found newer than ${current_channel}"
        return 3
    fi

    echo "${next_channel}"
}

wait_for_csv_succeeded() {
    local previous_csv="$1"
    local timeout_seconds
    timeout_seconds="$(parse_timeout "${ACM_UPGRADE_TIMEOUT}")"
    local start_time elapsed new_csv phase
    start_time="$(date +%s)"

    while true; do
        elapsed="$(( $(date +%s) - start_time ))"
        if (( elapsed > timeout_seconds )); then
            echo >&2 "ERROR: Timeout (${ACM_UPGRADE_TIMEOUT}) waiting for CSV upgrade"
            return 2
        fi

        new_csv="$(get_current_csv)"
        if [[ -z "${new_csv}" || "${new_csv}" == "${previous_csv}" ]]; then
            sleep 10
            continue
        fi

        phase="$(get_csv_phase "${new_csv}")"
        echo "  CSV: ${new_csv}  Phase: ${phase}  (${elapsed}s elapsed)"

        case "${phase}" in
            Succeeded)
                return 0
                ;;
            Failed)
                echo >&2 "ERROR: CSV ${new_csv} entered Failed phase"
                return 1
                ;;
            *)
                sleep 15
                ;;
        esac
    done
}

parse_timeout() {
    local input="$1"
    local minutes=0 seconds=0
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
}

validate_mce_upgrade() {
    echo "Validating MCE (MultiCluster Engine) upgrade..."
    local mce_csv
    mce_csv="$(oc get csv -n multicluster-engine \
        -o jsonpath='{.items[?(@.spec.displayName=="multicluster engine for Kubernetes")].metadata.name}' \
        2>/dev/null || true)"

    if [[ -z "${mce_csv}" ]]; then
        mce_csv="$(oc get csv -n multicluster-engine \
            -l operators.coreos.com/multicluster-engine.multicluster-engine= \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi

    if [[ -z "${mce_csv}" ]]; then
        echo "WARNING: MCE CSV not found; skipping MCE validation"
        return 0
    fi

    local mce_phase
    mce_phase="$(oc get csv "${mce_csv}" -n multicluster-engine \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"

    echo "  MCE CSV: ${mce_csv}  Phase: ${mce_phase}"
    if [[ "${mce_phase}" != "Succeeded" ]]; then
        echo "WARNING: MCE CSV phase is ${mce_phase}, not Succeeded"
        local timeout_end
        timeout_end="$(( $(date +%s) + 300 ))"
        while (( $(date +%s) < timeout_end )); do
            mce_phase="$(oc get csv "${mce_csv}" -n multicluster-engine \
                -o jsonpath='{.status.phase}' 2>/dev/null || true)"
            if [[ "${mce_phase}" == "Succeeded" ]]; then
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

validate_hub_health() {
    echo "Validating ACM hub health post-upgrade..."

    local mch_status
    mch_status="$(oc get multiclusterhub -A \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    echo "  MultiClusterHub phase: ${mch_status}"

    if [[ "${mch_status}" != "Running" ]]; then
        echo "  Waiting for MCH to reach Running phase (timeout: 5m)..."
        local timeout_end
        timeout_end="$(( $(date +%s) + 300 ))"
        while (( $(date +%s) < timeout_end )); do
            mch_status="$(oc get multiclusterhub -A \
                -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
            if [[ "${mch_status}" == "Running" ]]; then
                break
            fi
            sleep 15
        done
        if [[ "${mch_status}" != "Running" ]]; then
            echo >&2 "ERROR: MultiClusterHub did not reach Running phase"
            return 1
        fi
    fi

    echo "  Checking policy propagator..."
    local propagator_ready
    propagator_ready="$(oc get pods -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -l name=governance-policy-propagator \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || true)"
    echo "  Policy propagator ready: ${propagator_ready}"

    echo "  Checking managed clusters..."
    local cluster_count available_count
    cluster_count="$(oc get managedclusters --no-headers 2>/dev/null | wc -l || echo 0)"
    available_count="$(oc get managedclusters \
        -o jsonpath='{.items[?(@.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status=="True")].metadata.name}' \
        2>/dev/null | wc -w || echo 0)"
    echo "  Managed clusters: ${available_count}/${cluster_count} available"

    echo "ACM hub health validation complete"
    return 0
}

# === Main ===

echo "=== ACM Operator Upgrade Step ==="
echo "Namespace: ${ACM_SUBSCRIPTION_NAMESPACE}"
echo "Subscription: ${ACM_SUBSCRIPTION_NAME}"
echo "Timeout: ${ACM_UPGRADE_TIMEOUT}"

current_csv="$(get_current_csv)"
if [[ -z "${current_csv}" ]]; then
    echo >&2 "ERROR: No ACM subscription found or no currentCSV set"
    exit 3
fi

current_version="$(get_installed_version)"
current_channel="$(get_current_channel)"
echo "Current: CSV=${current_csv} Version=${current_version} Channel=${current_channel}"

target_channel="$(resolve_target_channel)"
echo "Target channel: ${target_channel}"

if [[ "${target_channel}" == "${current_channel}" ]]; then
    echo "Already on target channel ${target_channel}; checking if upgrade is available..."
    install_plan="$(oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"
    if [[ -z "${install_plan}" ]]; then
        echo "No pending upgrade on current channel; nothing to do"
        exit 0
    fi
    plan_phase="$(oc get installplan "${install_plan}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${plan_phase}" == "Complete" ]]; then
        echo "InstallPlan ${install_plan} already complete; no pending upgrade"
        exit 0
    fi
fi

echo "Patching subscription channel: ${current_channel} -> ${target_channel}"
oc patch subscription "${ACM_SUBSCRIPTION_NAME}" \
    -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
    --type merge \
    -p "{\"spec\":{\"channel\":\"${target_channel}\"}}"

echo "Waiting for InstallPlan to be created..."
sleep 10

install_plan=""
for _ in $(seq 1 12); do
    install_plan="$(oc get subscription "${ACM_SUBSCRIPTION_NAME}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"
    if [[ -z "${install_plan}" ]]; then
        install_plan="$(oc get installplan -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
            --sort-by=.metadata.creationTimestamp \
            -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    fi
    if [[ -n "${install_plan}" ]]; then
        break
    fi
    sleep 10
done

if [[ -n "${install_plan}" ]]; then
    echo "InstallPlan: ${install_plan}"
    local_approval="$(oc get installplan "${install_plan}" \
        -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
        -o jsonpath='{.spec.approval}' 2>/dev/null || true)"
    if [[ "${local_approval}" == "Manual" ]]; then
        echo "Approving manual InstallPlan..."
        oc patch installplan "${install_plan}" \
            -n "${ACM_SUBSCRIPTION_NAMESPACE}" \
            --type merge \
            -p '{"spec":{"approved":true}}'
    fi
fi

echo "Waiting for ACM CSV to reach Succeeded phase..."
wait_for_csv_succeeded "${current_csv}"
new_csv="$(get_current_csv)"
new_version="$(get_installed_version)"
echo "Upgrade complete: ${current_version} -> ${new_version} (CSV: ${new_csv})"

validate_mce_upgrade
validate_hub_health

{
    printf '=== ACM Operator Upgrade Summary ===\n'
    printf 'Previous: %s (%s)\n' "${current_version}" "${current_channel}"
    printf 'Current:  %s (%s)\n' "${new_version}" "${target_channel}"
    printf 'CSV:      %s\n' "${new_csv}"
    printf 'Status:   SUCCESS\n'
} > "${ARTIFACT_DIR}/acm-upgrade-summary.txt"

if [[ -n "${SHARED_DIR:-}" ]]; then
    echo "${new_version}" > "${SHARED_DIR}/acm-upgraded-version"
    echo "${target_channel}" > "${SHARED_DIR}/acm-upgraded-channel"
fi

echo "=== ACM Operator Upgrade: SUCCESS ==="
