#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"

REPORT_DIR="${ARTIFACT_DIR}/preflight"
REPORT_FILE="${REPORT_DIR}/preflight-report.json"
mkdir -p "${REPORT_DIR}"

CHECKS_FAILED=0

debug_on_exit() {
    if (( EXIT_CODE != 0 )); then
        echo -e "\n### DEBUG: Pre-flight failure diagnostics ###\n"
        echo -e "\n# ClusterVersion\n$(oc get clusterversion 2>/dev/null || echo 'unavailable')"
        echo -e "\n# ClusterOperators\n$(oc get co 2>/dev/null || echo 'unavailable')"
        echo -e "\n# MachineConfigPools\n$(oc get machineconfigpools 2>/dev/null || echo 'unavailable')"
        echo -e "\n# Nodes\n$(oc get nodes 2>/dev/null || echo 'unavailable')"
        echo -e "\n# OPP Operator CSVs\n$(oc get csv -A 2>/dev/null || echo 'unavailable')"
        if [[ -f "${REPORT_FILE}" ]]; then
            echo -e "\n# Pre-flight report:\n$(cat "${REPORT_FILE}")"
        fi
    fi
}

trap 'EXIT_CODE=$?; debug_on_exit' EXIT TERM

# ──────────────────────────────────────────────────────────────────────
#  Known removed / deprecated APIs per OCP minor version.
#  Each entry lists the API group/version and the resource kind that
#  was removed IN that minor version (i.e. no longer available).
#  Source: Kubernetes deprecation guide + OCP release notes.
# ──────────────────────────────────────────────────────────────────────
declare -A REMOVED_APIS
# APIs removed in 4.12 (Kubernetes 1.25)
REMOVED_APIS["12"]="batch/v1beta1/CronJob policy/v1beta1/PodDisruptionBudget policy/v1beta1/PodSecurityPolicy discovery.k8s.io/v1beta1/EndpointSlice events.k8s.io/v1beta1/Event autoscaling/v2beta1/HorizontalPodAutoscaler"
# APIs removed in 4.14 (Kubernetes 1.27)
REMOVED_APIS["14"]="storage.k8s.io/v1beta1/CSIStorageCapacity"
# APIs removed in 4.17 (Kubernetes 1.30)
REMOVED_APIS["17"]="flowcontrol.apiserver.k8s.io/v1beta2/FlowSchema flowcontrol.apiserver.k8s.io/v1beta2/PriorityLevelConfiguration"
# APIs removed in 4.18 (Kubernetes 1.31)
REMOVED_APIS["18"]="flowcontrol.apiserver.k8s.io/v1beta3/FlowSchema flowcontrol.apiserver.k8s.io/v1beta3/PriorityLevelConfiguration"

# ──────────────────────────────────────────────────────────────────────
#  OPP operator compatibility matrix.
#  Maps OCP minor version to minimum required operator major.minor.
#  Format: "operator_csv_prefix:min_major.min_minor"
# ──────────────────────────────────────────────────────────────────────
declare -A OPP_COMPAT
OPP_COMPAT["14"]="advanced-cluster-management:2.9 rhacs-operator:4.3 odf-operator:4.14 quay-operator:3.10"
OPP_COMPAT["15"]="advanced-cluster-management:2.10 rhacs-operator:4.4 odf-operator:4.15 quay-operator:3.11"
OPP_COMPAT["16"]="advanced-cluster-management:2.11 rhacs-operator:4.5 odf-operator:4.16 quay-operator:3.12"
OPP_COMPAT["17"]="advanced-cluster-management:2.12 rhacs-operator:4.6 odf-operator:4.17 quay-operator:3.13"
OPP_COMPAT["18"]="advanced-cluster-management:2.13 rhacs-operator:4.7 odf-operator:4.18 quay-operator:3.14"
OPP_COMPAT["19"]="advanced-cluster-management:2.13 rhacs-operator:4.8 odf-operator:4.19 quay-operator:3.14"
OPP_COMPAT["20"]="advanced-cluster-management:2.14 rhacs-operator:4.9 odf-operator:4.20 quay-operator:3.15"
OPP_COMPAT["21"]="advanced-cluster-management:2.15 rhacs-operator:4.10 odf-operator:4.21 quay-operator:3.15"
OPP_COMPAT["22"]="advanced-cluster-management:2.16 rhacs-operator:4.11 odf-operator:4.22 quay-operator:3.16"

# ──────────────────────────────────────────────────────────────────────
#  Utility: append a check result to the JSON report
# ──────────────────────────────────────────────────────────────────────
init_report() {
    cat > "${REPORT_FILE}" <<'EOFJSON'
{
  "preflight_checks": []
}
EOFJSON
}

append_check() {
    local name="${1}" status="${2}" details="${3}"
    local tmp
    tmp="$(mktemp)"
    jq --arg n "${name}" --arg s "${status}" --arg d "${details}" \
        '.preflight_checks += [{"check": $n, "status": $s, "details": $d}]' \
        "${REPORT_FILE}" > "${tmp}" && mv "${tmp}" "${REPORT_FILE}"
}

# ──────────────────────────────────────────────────────────────────────
#  Check 1: API deprecation scan
# ──────────────────────────────────────────────────────────────────────
check_api_deprecations() {
    echo "=== Check 1: API deprecation scan ==="

    local target_minor="${1}"
    local flagged="" found_count=0

    # Collect available API resources on the cluster
    local cluster_apis
    cluster_apis="$(oc api-resources --no-headers 2>/dev/null)" || {
        echo "WARNING: Failed to list API resources"
        append_check "api_deprecation_scan" "warn" "Could not list cluster API resources"
        return 0
    }

    # Check all versions up to and including the target
    for minor in "${!REMOVED_APIS[@]}"; do
        if (( minor <= target_minor )); then
            for api_entry in ${REMOVED_APIS[${minor}]}; do
                local api_version api_kind
                api_kind="${api_entry##*/}"
                api_version="${api_entry%/*}"

                # Check if this deprecated API version+kind is still served
                if echo "${cluster_apis}" | grep -qw "${api_kind}" && \
                   oc api-resources --api-group="${api_version%%/*}" 2>/dev/null | grep -q "${api_version#*/}"; then
                    # Check if any OPP workloads reference this API
                    local opp_usage
                    opp_usage="$(oc get "${api_kind}" -A --no-headers 2>/dev/null | head -5)" || true
                    if [[ -n "${opp_usage}" ]]; then
                        flagged="${flagged}  - ${api_version}/${api_kind} (removed in 4.${minor})\n"
                        (( found_count += 1 ))
                    fi
                fi
            done
        fi
    done

    if (( found_count > 0 )); then
        echo -e "WARNING: Found ${found_count} deprecated API(s) still in use:\n${flagged}"
        append_check "api_deprecation_scan" "warn" "Found ${found_count} deprecated API(s) in use: ${flagged}"
    else
        echo "No deprecated APIs detected for target version 4.${target_minor}"
        append_check "api_deprecation_scan" "pass" "No deprecated APIs detected"
    fi
}

# ──────────────────────────────────────────────────────────────────────
#  Check 2: OPP compatibility matrix
# ──────────────────────────────────────────────────────────────────────
check_opp_compatibility() {
    echo -e "\n=== Check 2: OPP operator compatibility matrix ==="

    local target_minor="${1}"
    local compat_spec="${OPP_COMPAT[${target_minor}]:-}"
    local all_csvs failed=0

    all_csvs="$(oc get csv -A --no-headers 2>/dev/null)" || {
        echo >&2 "Failed to retrieve CSVs"
        append_check "opp_compatibility_matrix" "fail" "Could not list CSVs"
        (( CHECKS_FAILED += 1 ))
        return 0
    }

    if [[ -z "${compat_spec}" ]]; then
        echo "No compatibility matrix entry for target minor ${target_minor}; skipping version check"
        append_check "opp_compatibility_matrix" "skip" "No matrix entry for OCP 4.${target_minor}"
        return 0
    fi

    local details=""
    for entry in ${compat_spec}; do
        local op_prefix="${entry%%:*}"
        local min_version="${entry##*:}"
        local min_major min_minor
        min_major="${min_version%%.*}"
        min_minor="${min_version##*.}"

        # Find installed CSV for this operator
        local csv_line csv_name installed_version
        csv_line="$(echo "${all_csvs}" | grep "${op_prefix}" | head -1)" || true
        if [[ -z "${csv_line}" ]]; then
            echo >&2 "Operator not found: ${op_prefix}"
            details="${details}${op_prefix}: NOT INSTALLED; "
            (( failed += 1 ))
            continue
        fi

        csv_name="$(echo "${csv_line}" | awk '{print $2}')"
        # Extract version: strip operator name prefix, keep digits
        installed_version="$(echo "${csv_name}" | grep -oE '[0-9]+\.[0-9]+' | head -1)" || true
        if [[ -z "${installed_version}" ]]; then
            echo "WARNING: Could not parse version from CSV ${csv_name}"
            details="${details}${op_prefix}: version unparseable from ${csv_name}; "
            continue
        fi

        local inst_major inst_minor
        inst_major="${installed_version%%.*}"
        inst_minor="${installed_version##*.}"

        if (( inst_major < min_major || (inst_major == min_major && inst_minor < min_minor) )); then
            echo >&2 "Operator ${op_prefix} version ${installed_version} is below minimum ${min_version} for OCP 4.${target_minor}"
            details="${details}${op_prefix}: ${installed_version} < ${min_version} (INCOMPATIBLE); "
            (( failed += 1 ))
        else
            echo "Operator ${op_prefix}: version ${installed_version} >= ${min_version} (OK)"
            details="${details}${op_prefix}: ${installed_version} >= ${min_version} (OK); "
        fi
    done

    if (( failed > 0 )); then
        echo >&2 "${failed} operator(s) failed compatibility check"
        append_check "opp_compatibility_matrix" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        echo "All OPP operators are compatible with OCP 4.${target_minor}"
        append_check "opp_compatibility_matrix" "pass" "${details}"
    fi
}

# ──────────────────────────────────────────────────────────────────────
#  Check 3: Cluster health baseline
# ──────────────────────────────────────────────────────────────────────
check_cluster_health() {
    echo -e "\n=== Check 3: Cluster health baseline ==="

    local failed=0 details=""

    # 3a. Node health
    echo "Checking node health..."
    local unready_nodes
    unready_nodes="$(oc get node --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}')" || true
    if [[ -n "${unready_nodes}" ]]; then
        echo >&2 "Not-Ready nodes: ${unready_nodes}"
        details="${details}unready_nodes: ${unready_nodes}; "
        (( failed += 1 ))
    else
        local node_count
        node_count="$(oc get node --no-headers 2>/dev/null | wc -l)"
        echo "All ${node_count} nodes Ready"
        details="${details}nodes: all ${node_count} ready; "
    fi

    # 3b. ClusterOperator health
    echo "Checking ClusterOperator health..."
    local unhealthy_co
    unhealthy_co="$(oc get co --no-headers 2>/dev/null | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')" || true
    if [[ -n "${unhealthy_co}" ]]; then
        echo >&2 "Unhealthy ClusterOperators: ${unhealthy_co}"
        details="${details}unhealthy_co: ${unhealthy_co}; "
        (( failed += 1 ))
    else
        echo "All ClusterOperators healthy"
        details="${details}cluster_operators: all healthy; "
    fi

    # 3c. CVO conditions
    echo "Checking ClusterVersion conditions..."
    local avail progressing degraded
    avail="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" || true
    progressing="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)" || true
    degraded="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null)" || true
    if [[ "${avail}" != "True" || "${progressing}" != "False" || "${degraded}" != "False" ]]; then
        echo >&2 "CVO health check failed: Available=${avail} Progressing=${progressing} Degraded=${degraded}"
        details="${details}cvo: Available=${avail} Progressing=${progressing} Degraded=${degraded}; "
        (( failed += 1 ))
    else
        echo "CVO: Available=True, Progressing=False, Degraded=False"
        details="${details}cvo: healthy; "
    fi

    # 3d. Firing alerts (excluding Watchdog and AlertmanagerReceiversNotConfigured)
    echo "Checking for firing alerts..."
    local firing_alerts=""
    firing_alerts="$(oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
        curl -s 'http://localhost:9090/api/v1/alerts' 2>/dev/null | \
        jq -r '.data.alerts[]? | select(.state=="firing") | select(.labels.alertname != "Watchdog") | select(.labels.alertname != "AlertmanagerReceiversNotConfigured") | .labels.alertname' 2>/dev/null | \
        sort -u)" || true

    if [[ -n "${firing_alerts}" ]]; then
        local alert_count
        alert_count="$(echo "${firing_alerts}" | wc -l)"
        echo "WARNING: ${alert_count} alert(s) firing: ${firing_alerts}"
        details="${details}firing_alerts: ${alert_count} (${firing_alerts}); "
        # Alerts are a warning, not a hard failure
    else
        echo "No critical alerts firing"
        details="${details}alerts: none firing; "
    fi

    # Save node and CO snapshot for baseline
    oc get nodes -o json > "${REPORT_DIR}/nodes-baseline.json" 2>/dev/null || true
    oc get co -o json > "${REPORT_DIR}/co-baseline.json" 2>/dev/null || true

    if (( failed > 0 )); then
        echo >&2 "Cluster health baseline: ${failed} issue(s) found"
        append_check "cluster_health_baseline" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        echo "Cluster health baseline: all checks passed"
        append_check "cluster_health_baseline" "pass" "${details}"
    fi
}

# ──────────────────────────────────────────────────────────────────────
#  Check 4: MachineConfigPool readiness
# ──────────────────────────────────────────────────────────────────────
check_mcp_readiness() {
    echo -e "\n=== Check 4: MachineConfigPool readiness ==="

    local failed=0 details=""

    # Check MCP conditions: Updated=True, Updating=False, Degraded=False
    local mcp_issues
    mcp_issues="$(oc get machineconfigpools --no-headers 2>/dev/null | \
        awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')" || true

    if [[ -n "${mcp_issues}" ]]; then
        echo >&2 "Unhealthy MachineConfigPools: ${mcp_issues}"
        details="unhealthy_mcps: ${mcp_issues}; "
        (( failed += 1 ))

        # Dump details for each unhealthy MCP
        for mcp in ${mcp_issues}; do
            echo -e "\n### MCP ${mcp} ###"
            oc describe machineconfigpool "${mcp}" 2>/dev/null || true
        done
    else
        local mcp_count
        mcp_count="$(oc get machineconfigpools --no-headers 2>/dev/null | wc -l)"
        echo "All ${mcp_count} MachineConfigPools are updated and not degraded"
        details="all ${mcp_count} MCPs healthy (Updated=True, Updating=False, Degraded=False); "
    fi

    # Check that machine counts match (ready == desired)
    local mismatch=""
    while IFS= read -r line; do
        local mcp_name ready desired
        mcp_name="$(echo "${line}" | awk '{print $1}')"
        ready="$(echo "${line}" | awk '{print $6}')"
        desired="$(echo "${line}" | awk '{print $7}')"
        if [[ -n "${ready}" && -n "${desired}" && "${ready}" != "${desired}" ]]; then
            mismatch="${mismatch}${mcp_name} (ready=${ready}, desired=${desired}); "
        fi
    done < <(oc get machineconfigpools --no-headers 2>/dev/null || true)

    if [[ -n "${mismatch}" ]]; then
        echo >&2 "MCP machine count mismatch: ${mismatch}"
        details="${details}machine_count_mismatch: ${mismatch}"
        (( failed += 1 ))
    fi

    # Save MCP snapshot
    oc get machineconfigpools -o json > "${REPORT_DIR}/mcp-baseline.json" 2>/dev/null || true

    if (( failed > 0 )); then
        echo >&2 "MachineConfigPool readiness: ${failed} issue(s) found"
        append_check "mcp_readiness" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        echo "MachineConfigPool readiness: all checks passed"
        append_check "mcp_readiness" "pass" "${details}"
    fi
}

# ──────────────────────────────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────────────────────────────
main() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    local target="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}"
    if [[ -z "${target}" ]]; then
        echo >&2 "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is not set; cannot determine upgrade target"
        exit 3
    fi
    echo "Target release image: ${target}"

    KUBECONFIG="" oc --loglevel=8 registry login

    local target_version target_minor
    target_version="$(oc adm release info "${target}" --output=json | jq -r '.metadata.version')"
    target_minor="$(echo "${target_version}" | cut -f2 -d.)"
    echo "Target OCP version: ${target_version} (minor: ${target_minor})"

    local source_version
    source_version="$(oc get clusterversion --no-headers | awk '{print $2}')"
    echo "Source OCP version: ${source_version}"

    echo -e "\n=== Starting OPP pre-flight validation ===\n"

    init_report

    # Add metadata to report
    local tmp
    tmp="$(mktemp)"
    jq --arg tv "${target_version}" --arg sv "${source_version}" --arg ti "${target}" \
        '. + {"target_version": $tv, "source_version": $sv, "target_image": $ti, "timestamp": now | tostring}' \
        "${REPORT_FILE}" > "${tmp}" && mv "${tmp}" "${REPORT_FILE}"

    check_api_deprecations "${target_minor}"
    check_opp_compatibility "${target_minor}"
    check_cluster_health
    check_mcp_readiness

    echo -e "\n=== Pre-flight summary ==="
    jq '.' "${REPORT_FILE}"

    if (( CHECKS_FAILED > 0 )); then
        echo >&2 "Pre-flight validation FAILED: ${CHECKS_FAILED} check(s) did not pass"
        echo >&2 "Review ${REPORT_FILE} for details"
        exit 3
    fi

    echo "Pre-flight validation PASSED: all checks succeeded"
}

main "$@"
