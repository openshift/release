#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

UPGRADE_TIMEOUT="${UPGRADE_TIMEOUT:-130}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
STALL_WINDOW="${STALL_WINDOW:-10}"
OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"

debug_on_exit() {
    if (( EXIT_CODE != 0 )); then
        echo -e "\n### DEBUG: Upgrade failure diagnostics ###\n"
        if [[ -n "${TARGET_MINOR_VERSION:-}" ]] && (( TARGET_MINOR_VERSION >= 16 )); then
            echo -e "\n# oc adm upgrade status\n"
            env OC_ENABLE_CMD_UPGRADE_STATUS='true' oc adm upgrade status --details=all || true
        fi
        echo -e "\n# ClusterVersion YAML\n$(oc get clusterversion/version -oyaml 2>/dev/null || echo 'unavailable')"
        echo -e "\n# MachineConfigs\n$(oc get machineconfig 2>/dev/null || echo 'unavailable')"

        echo -e "\n# Abnormal nodes\n"
        oc get node --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}' | while read -r node; do
            echo -e "\n### oc describe node ${node} ###\n$(oc describe node "${node}" 2>/dev/null)"
        done

        echo -e "\n# Abnormal ClusterOperators\n"
        oc get co --no-headers 2>/dev/null | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read -r co; do
            echo -e "\n### oc describe co ${co} ###\n$(oc describe co "${co}" 2>/dev/null)"
        done

        echo -e "\n# Abnormal MachineConfigPools\n"
        oc get machineconfigpools --no-headers 2>/dev/null | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read -r mcp; do
            echo -e "\n### oc describe mcp ${mcp} ###\n$(oc describe mcp "${mcp}" 2>/dev/null)"
        done

        echo -e "\n# OPP Operator CSVs\n$(oc get csv -A 2>/dev/null || echo 'unavailable')"
    fi
}

trap 'EXIT_CODE=$?; debug_on_exit' EXIT TERM

KUBECONFIG="" oc --loglevel=8 registry login

resolve_target_image() {
    local target="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}"
    if [[ -z "${target}" ]]; then
        echo >&2 "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is not set; cannot resolve upgrade target"
        exit 3
    fi
    echo "Target image: ${target}"
    TARGET="${target}"
}

check_signed() {
    local digest algorithm hash_value response try max_retries=3 payload="${1}"
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
    else
        digest="$(oc image info "${payload}" -o json | jq -r '.digest')"
    fi
    echo "Image digest: ${digest}"
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    try=0
    response=0
    while (( try < max_retries && response != 200 )); do
        echo "Signature check attempt #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null \
            --write-out "%{http_code}" \
            "https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
        (( try += 1 ))
        if (( response != 200 && try < max_retries )); then
            sleep 60
        fi
    done
    if (( response == 200 )); then
        echo "Image is signed" && return 0
    else
        echo "Image is not signed" && return 1
    fi
}

admin_ack() {
    local source_minor="${1}" target_minor="${2}"
    if (( source_minor == target_minor )) || (( source_minor < 8 )); then
        echo "Admin ack not required (z-stream or pre-4.8)" && return 0
    fi

    local gates
    gates="$(oc -n openshift-config-managed get configmap admin-gates -o json 2>/dev/null | jq -r '.data' 2>/dev/null)" || true
    if [[ -z "${gates}" || "${gates}" == "null" ]]; then
        echo "No admin gates found" && return 0
    fi
    echo -e "Admin gates:\n${gates}"

    if [[ ${gates} != *"ack-4.${source_minor}"* ]]; then
        echo "No acks required for source minor version ${source_minor}" && return 0
    fi

    echo "Patching admin acks for 4.${source_minor} -> 4.${target_minor}"
    local ack_keys
    ack_keys="$(echo "${gates}" | jq -r 'keys[]')"
    for ack in ${ack_keys}; do
        if [[ "${ack}" == *"ack-4.${source_minor}"* ]]; then
            echo "Applying ack: ${ack}"
            oc -n openshift-config patch configmap admin-acks \
                --patch '{"data":{"'"${ack}"'": "true"}}' --type=merge
        fi
    done

    echo "Waiting for admin acks to take effect (up to 5 minutes)"
    local elapsed=0
    while (( elapsed < 5 )); do
        sleep 1m
        (( elapsed += 1 ))
        if ! oc adm upgrade 2>&1 | grep -q "AdminAckRequired"; then
            echo "Admin acks applied successfully"
            return 0
        fi
        echo "Still waiting... (${elapsed}/5 min)"
    done
    echo >&2 "Timed out waiting for admin acks"
    return 1
}

update_cco_annotation() {
    local source_version="${1}" target_version="${2}"
    local source_minor target_minor
    source_minor="$(echo "${source_version}" | cut -f2 -d.)"
    target_minor="$(echo "${target_version}" | cut -f2 -d.)"

    if (( source_minor == target_minor )) || (( source_minor < 8 )); then
        echo "CCO annotation not required (z-stream or pre-4.8)" && return 0
    fi

    local cco_mode
    cco_mode="$(oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}' 2>/dev/null)" || true
    if [[ "${cco_mode}" != "Manual" ]]; then
        echo "CCO annotation not required (mode: ${cco_mode:-default})" && return 0
    fi

    local to_version
    to_version="$(echo "${target_version}" | cut -f1 -d-)"
    echo "Patching CCO upgradeable-to annotation: ${to_version}"
    oc patch cloudcredential.operator.openshift.io/cluster \
        --patch '{"metadata":{"annotations": {"cloudcredential.openshift.io/upgradeable-to": "'"${to_version}"'"}}}' \
        --type=merge

    echo "Waiting for CCO annotation to take effect (up to 5 minutes)"
    local elapsed=0
    while (( elapsed < 5 )); do
        sleep 1m
        (( elapsed += 1 ))
        if ! oc adm upgrade 2>&1 | grep -q "MissingUpgradeableAnnotation"; then
            echo "CCO annotation applied successfully"
            return 0
        fi
        echo "Still waiting... (${elapsed}/5 min)"
    done
    echo >&2 "Timed out waiting for CCO annotation"
    return 1
}

initiate_upgrade() {
    local force_flag="${1}"
    echo "Initiating upgrade to ${TARGET}"
    echo "Force flag: ${force_flag}"
    oc adm upgrade --to-image="${TARGET}" --allow-explicit-upgrade --force="${force_flag}"
    echo "Upgrade command accepted at $(date '+%F %T')"

    sleep 10
    local progressing
    progressing="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)" || true
    if [[ "${progressing}" != "True" ]]; then
        echo >&2 "WARNING: CVO Progressing is not True after upgrade initiation (status: ${progressing})"
    else
        echo "CVO confirmed Progressing=True"
    fi
}

monitor_upgrade() {
    local poll_count=0
    local last_progress_change
    last_progress_change=$(date +%s)

    local stat_cmd="oc adm upgrade 2>&1 | grep -vE 'Upstream is unset|Upstream: https|available channels|No updates available|^$'"
    if (( TARGET_MINOR_VERSION >= 16 )); then
        stat_cmd="env OC_ENABLE_CMD_UPGRADE_STATUS=true oc adm upgrade status 2>&1 | grep -vE 'no token is currently in use|for additional description and links'"
    fi

    local prev_status=""
    local snapshot_dir="${ARTIFACT_DIR:-/tmp}/upgrade-progress"
    mkdir -p "${snapshot_dir}"

    echo "Monitoring upgrade (timeout: ${UPGRADE_TIMEOUT}m, poll: ${POLL_INTERVAL}s)"
    echo "Upgrade monitoring start: $(date '+%F %T')"
    local start_time deadline
    start_time=$(date +%s)
    deadline=$(( start_time + UPGRADE_TIMEOUT * 60 ))

    while (( $(date +%s) < deadline )); do
        sleep "${POLL_INTERVAL}"
        (( poll_count += 1 ))

        local current_status
        current_status="$(eval "${stat_cmd}" 2>/dev/null)" || true
        if [[ -n "${current_status}" && "${current_status}" != "${prev_status}" ]]; then
            echo -e "=== Upgrade Status $(date '+%T') ===\n${current_status}\n"
            prev_status="${current_status}"
            last_progress_change=$(date +%s)
        fi

        if (( poll_count % 5 == 0 )); then
            oc get clusterversion version -o json > "${snapshot_dir}/cv-$(date +%s).json" 2>/dev/null || true
        fi

        local cv_out avail progressing
        cv_out="$(oc get clusterversion --no-headers 2>/dev/null)" || continue
        avail="$(echo "${cv_out}" | awk '{print $3}')"
        progressing="$(echo "${cv_out}" | awk '{print $4}')"

        if [[ "${avail}" == "True" && "${progressing}" == "False" && "${cv_out}" == *"${TARGET_VERSION}"* ]]; then
            local end_time
            end_time=$(date +%s)
            echo "Upgrade completed successfully at $(date '+%F %T')"
            echo "Elapsed: $(( (end_time - start_time) / 60 ))m"
            return 0
        fi

        local now stall_seconds
        now=$(date +%s)
        stall_seconds=$(( STALL_WINDOW * 60 ))
        if (( now - last_progress_change > stall_seconds )); then
            echo "WARNING: No upgrade progress change in ${STALL_WINDOW} minutes (possible stall)"
            oc get clusterversion version -o json > "${snapshot_dir}/cv-stall-$(date +%s).json" 2>/dev/null || true
        fi
    done

    local end_time
    end_time=$(date +%s)
    echo >&2 "Upgrade timed out after ${UPGRADE_TIMEOUT} minutes at $(date '+%F %T')"
    echo >&2 "Elapsed: $(( (end_time - start_time) / 60 ))m"
    exit 2
}

stabilize_cluster() {
    echo "Waiting for cluster stability (minimum-stable-period=5m, timeout=30m)"
    oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=30m
    echo "Cluster is stable"
}

validate_platform_health() {
    echo "Validating platform health"

    local avail progressing degraded
    avail="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
    progressing="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')"
    degraded="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')"
    if [[ "${avail}" != "True" || "${progressing}" != "False" || "${degraded}" != "False" ]]; then
        echo >&2 "CVO health check failed: Available=${avail} Progressing=${progressing} Degraded=${degraded}"
        return 1
    fi
    echo "CVO: Available=True, Progressing=False, Degraded=False"

    local unhealthy_co
    unhealthy_co="$(oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')"
    if [[ -n "${unhealthy_co}" ]]; then
        echo >&2 "Unhealthy ClusterOperators: ${unhealthy_co}"
        return 1
    fi
    echo "All ClusterOperators healthy"

    local unready_nodes
    unready_nodes="$(oc get node --no-headers | awk '$2 != "Ready" {print $1}')"
    if [[ -n "${unready_nodes}" ]]; then
        echo >&2 "Not-Ready nodes: ${unready_nodes}"
        return 1
    fi
    echo "All nodes Ready"

    local mcp_issues
    mcp_issues="$(oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')"
    if [[ -n "${mcp_issues}" ]]; then
        echo >&2 "Unhealthy MachineConfigPools: ${mcp_issues}"
        return 1
    fi
    echo "All MachineConfigPools updated"
}

validate_opp_operators() {
    echo "Validating OPP operator health"
    local operators
    IFS=',' read -ra operators <<< "${OPP_OPERATORS}"

    echo "Waiting 5 minutes for operator settling"
    sleep 300

    local all_csvs failed=0
    all_csvs="$(oc get csv -A --no-headers 2>/dev/null)" || {
        echo >&2 "Failed to retrieve CSVs"
        return 1
    }

    for op in "${operators[@]}"; do
        local csv_line phase
        csv_line="$(echo "${all_csvs}" | grep "${op}" | head -1)" || true
        if [[ -z "${csv_line}" ]]; then
            echo >&2 "CSV not found for operator: ${op}"
            (( failed += 1 ))
            continue
        fi
        phase="$(echo "${csv_line}" | awk '{print $NF}')"
        if [[ "${phase}" != "Succeeded" ]]; then
            echo >&2 "Operator ${op} CSV phase: ${phase} (expected: Succeeded)"
            (( failed += 1 ))
        else
            echo "Operator ${op}: CSV phase Succeeded"
        fi
    done

    if (( failed > 0 )); then
        echo >&2 "${failed} OPP operator(s) not healthy after upgrade"
        echo -e "\nFull CSV listing:\n${all_csvs}"
        return 1
    fi

    echo "Checking pod readiness for OPP operator namespaces"
    local opp_namespaces
    opp_namespaces="$(echo "${all_csvs}" | grep -E "$(echo "${OPP_OPERATORS}" | tr ',' '|')" | awk '{print $1}' | sort -u)"
    for ns in ${opp_namespaces}; do
        local not_ready
        not_ready="$(oc get pods -n "${ns}" --no-headers 2>/dev/null | grep -v 'Completed' | grep -v 'Running' | grep -v 'Succeeded')" || true
        if [[ -n "${not_ready}" ]]; then
            echo "WARNING: Non-running pods in ${ns}:"
            echo "${not_ready}"
        else
            echo "All pods healthy in ${ns}"
        fi
    done

    echo "All OPP operators validated successfully"
}

main() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    resolve_target_image

    TARGET_VERSION="$(oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
    TARGET_MINOR_VERSION="$(echo "${TARGET_VERSION}" | cut -f2 -d.)"
    export TARGET_VERSION TARGET_MINOR_VERSION
    echo "Target release: ${TARGET_VERSION} (minor: ${TARGET_MINOR_VERSION})"

    SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
    SOURCE_MINOR_VERSION="$(echo "${SOURCE_VERSION}" | cut -f2 -d.)"
    export SOURCE_VERSION SOURCE_MINOR_VERSION
    echo "Source release: ${SOURCE_VERSION} (minor: ${SOURCE_MINOR_VERSION})"

    FORCE_UPDATE="false"
    if ! check_signed "${TARGET}"; then
        echo "Target is unsigned; will use --force"
        FORCE_UPDATE="true"
    fi

    if [[ "${FORCE_UPDATE}" == "false" ]]; then
        admin_ack "${SOURCE_MINOR_VERSION}" "${TARGET_MINOR_VERSION}"
        update_cco_annotation "${SOURCE_VERSION}" "${TARGET_VERSION}"
    fi

    initiate_upgrade "${FORCE_UPDATE}"
    monitor_upgrade
    stabilize_cluster
    validate_platform_health
    validate_opp_operators
    echo "OCP upgrade and OPP validation completed successfully"
}

main "$@"
