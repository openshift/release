#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"

if ! command -v jq &>/dev/null; then
    echo "jq not found; installing..."
    dnf install -y -q jq 2>/dev/null || yum install -y -q jq 2>/dev/null || {
        echo >&2 "ERROR: failed to install jq"
        exit 1
    }
fi

REPORT_DIR="${ARTIFACT_DIR}/preflight"
REPORT_FILE="${REPORT_DIR}/preflight-report.json"
mkdir -p "${REPORT_DIR}"

CHECKS_FAILED=0

DebugOnExit() {
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
    true
}

trap 'EXIT_CODE=$?; DebugOnExit' EXIT TERM

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
OPP_COMPAT["4.14"]="advanced-cluster-management:2.9 rhacs-operator:4.3 odf-operator:4.14 quay-operator:3.10"
OPP_COMPAT["4.15"]="advanced-cluster-management:2.10 rhacs-operator:4.4 odf-operator:4.15 quay-operator:3.11"
OPP_COMPAT["4.16"]="advanced-cluster-management:2.11 rhacs-operator:4.5 odf-operator:4.16 quay-operator:3.12"
OPP_COMPAT["4.17"]="advanced-cluster-management:2.12 rhacs-operator:4.6 odf-operator:4.17 quay-operator:3.13"
OPP_COMPAT["4.18"]="advanced-cluster-management:2.13 rhacs-operator:4.7 odf-operator:4.18 quay-operator:3.14"
OPP_COMPAT["4.19"]="advanced-cluster-management:2.13 rhacs-operator:4.8 odf-operator:4.19 quay-operator:3.14"
OPP_COMPAT["4.20"]="advanced-cluster-management:2.14 rhacs-operator:4.9 odf-operator:4.20 quay-operator:3.15"
OPP_COMPAT["4.21"]="advanced-cluster-management:2.15 rhacs-operator:4.10 odf-operator:4.21 quay-operator:3.15"
OPP_COMPAT["4.22"]="advanced-cluster-management:2.17 rhacs-operator:4.11 odf-operator:4.22 quay-operator:3.16"
OPP_COMPAT["5.0"]="advanced-cluster-management:2.17 quay-operator:3.17"

# ──────────────────────────────────────────────────────────────────────
#  Utility: append a check result to the JSON report
# ──────────────────────────────────────────────────────────────────────
InitReport() {
    cat > "${REPORT_FILE}" <<'EOFJSON'
{
  "preflight_checks": []
}
EOFJSON
    true
}

AppendCheck() {
    typeset checkName="${1}" checkStatus="${2}" checkDetails="${3}"
    typeset tmpFile
    tmpFile="$(mktemp)"
    jq --arg n "${checkName}" --arg s "${checkStatus}" --arg d "${checkDetails}" \
        '.preflight_checks += [{"check": $n, "status": $s, "details": $d}]' \
        "${REPORT_FILE}" > "${tmpFile}" && mv "${tmpFile}" "${REPORT_FILE}"
    true
}

# ──────────────────────────────────────────────────────────────────────
#  Check 1: API deprecation scan
# ──────────────────────────────────────────────────────────────────────
CheckApiDeprecations() {
    echo "=== Check 1: API deprecation scan ==="

    typeset targetMinor="${1}"
    typeset ocpDisplay="${2:-4.${targetMinor}}"
    typeset targetMajor="${ocpDisplay%%.*}"
    typeset flagged="" foundCount=0

    typeset clusterApis
    clusterApis="$(oc api-resources --no-headers 2>/dev/null)" || {
        echo "WARNING: Failed to list API resources"
        AppendCheck "api_deprecation_scan" "warn" "Could not list cluster API resources"
        return 0
    }

    for minor in "${!REMOVED_APIS[@]}"; do
        if (( targetMajor > 4 || minor <= targetMinor )); then
            for apiEntry in ${REMOVED_APIS[${minor}]}; do
                typeset apiVersion apiKind
                apiKind="${apiEntry##*/}"
                apiVersion="${apiEntry%/*}"

                if echo "${clusterApis}" | grep -qw "${apiKind}" && \
                   oc api-resources --api-group="${apiVersion%%/*}" 2>/dev/null | grep -q "${apiVersion#*/}"; then
                    typeset oppUsage
                    oppUsage="$(oc get "${apiKind}" -A --no-headers 2>/dev/null | head -5)" || true
                    if [[ -n "${oppUsage}" ]]; then
                        flagged="${flagged}  - ${apiVersion}/${apiKind} (removed in ${targetMajor}.${minor})\n"
                        (( foundCount += 1 ))
                    fi
                fi
            done
        fi
    done

    if (( foundCount > 0 )); then
        echo -e "WARNING: Found ${foundCount} deprecated API(s) still in use:\n${flagged}"
        AppendCheck "api_deprecation_scan" "warn" "Found ${foundCount} deprecated API(s) in use: ${flagged}"
    else
        echo "No deprecated APIs detected for target version ${ocpDisplay}"
        AppendCheck "api_deprecation_scan" "pass" "No deprecated APIs detected for ${ocpDisplay}"
    fi
    true
}

# ──────────────────────────────────────────────────────────────────────
#  Check 2: OPP compatibility matrix
# ──────────────────────────────────────────────────────────────────────
CheckOppCompatibility() {
    echo -e "\n=== Check 2: OPP operator compatibility matrix ==="

    typeset ocpKey="${1}"
    typeset compatSpec="${OPP_COMPAT[${ocpKey}]:-}"
    typeset allCsvs
    typeset failed=0

    allCsvs="$(oc get csv -A --no-headers 2>/dev/null)" || {
        echo >&2 "Failed to retrieve CSVs"
        AppendCheck "opp_compatibility_matrix" "fail" "Could not list CSVs"
        (( CHECKS_FAILED += 1 ))
        return 0
    }

    if [[ -z "${compatSpec}" ]]; then
        echo "No compatibility matrix entry for OCP ${ocpKey}; skipping version check"
        AppendCheck "opp_compatibility_matrix" "skip" "No matrix entry for OCP ${ocpKey}"
        return 0
    fi

    typeset details=""
    for entry in ${compatSpec}; do
        typeset opPrefix="${entry%%:*}"
        typeset minVersion="${entry##*:}"
        typeset minMajor minMinor
        minMajor="${minVersion%%.*}"
        minMinor="${minVersion##*.}"

        typeset csvLine csvName installedVersion
        csvLine="$(echo "${allCsvs}" | grep "${opPrefix}" | head -1)" || true
        if [[ -z "${csvLine}" ]]; then
            echo >&2 "Operator not found: ${opPrefix}"
            details="${details}${opPrefix}: NOT INSTALLED; "
            (( failed += 1 ))
            continue
        fi

        csvName="$(echo "${csvLine}" | awk '{print $2}')"
        installedVersion="$(echo "${csvName}" | grep -oE '[0-9]+\.[0-9]+' | head -1)" || true
        if [[ -z "${installedVersion}" ]]; then
            echo >&2 "Operator ${opPrefix}: could not parse version from CSV ${csvName}"
            details="${details}${opPrefix}: version unparseable from ${csvName}; "
            (( failed += 1 ))
            continue
        fi

        typeset instMajor instMinor
        instMajor="${installedVersion%%.*}"
        instMinor="${installedVersion##*.}"

        if (( instMajor < minMajor || (instMajor == minMajor && instMinor < minMinor) )); then
            echo >&2 "Operator ${opPrefix} version ${installedVersion} is below minimum ${minVersion} for OCP ${ocpKey}"
            details="${details}${opPrefix}: ${installedVersion} < ${minVersion} (INCOMPATIBLE); "
            (( failed += 1 ))
        else
            echo "Operator ${opPrefix}: version ${installedVersion} >= ${minVersion} (OK)"
            details="${details}${opPrefix}: ${installedVersion} >= ${minVersion} (OK); "
        fi
    done

    if (( failed > 0 )); then
        echo >&2 "${failed} operator(s) failed compatibility check"
        AppendCheck "opp_compatibility_matrix" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        echo "All OPP operators are compatible with OCP ${ocpKey}"
        AppendCheck "opp_compatibility_matrix" "pass" "${details}"
    fi
    true
}

# ──────────────────────────────────────────────────────────────────────
#  Check 3: Cluster health baseline
# ──────────────────────────────────────────────────────────────────────
CheckClusterHealth() {
    echo -e "\n=== Check 3: Cluster health baseline ==="

    typeset failed=0 details=""

    echo "Checking node health..."
    typeset unreadyNodes
    unreadyNodes="$(oc get node --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}')" || true
    if [[ -n "${unreadyNodes}" ]]; then
        echo >&2 "Not-Ready nodes: ${unreadyNodes}"
        details="${details}unready_nodes: ${unreadyNodes}; "
        (( failed += 1 ))
    else
        typeset nodeCount
        nodeCount="$(oc get node --no-headers 2>/dev/null | wc -l)"
        echo "All ${nodeCount} nodes Ready"
        details="${details}nodes: all ${nodeCount} ready; "
    fi

    echo "Checking ClusterOperator health..."
    typeset unhealthyCo
    unhealthyCo="$(oc get co --no-headers 2>/dev/null | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')" || true
    if [[ -n "${unhealthyCo}" ]]; then
        echo >&2 "Unhealthy ClusterOperators: ${unhealthyCo}"
        details="${details}unhealthy_co: ${unhealthyCo}; "
        (( failed += 1 ))
    else
        echo "All ClusterOperators healthy"
        details="${details}cluster_operators: all healthy; "
    fi

    echo "Checking ClusterVersion conditions..."
    typeset avail progressing degraded
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

    echo "Checking for firing alerts..."
    typeset firingAlerts=""
    firingAlerts="$(oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
        curl -s 'http://localhost:9090/api/v1/alerts' 2>/dev/null | \
        jq -r '.data.alerts[]? | select(.state=="firing") | select(.labels.alertname != "Watchdog") | select(.labels.alertname != "AlertmanagerReceiversNotConfigured") | .labels.alertname' 2>/dev/null | \
        sort -u)" || true

    if [[ -n "${firingAlerts}" ]]; then
        typeset alertCount
        alertCount="$(echo "${firingAlerts}" | wc -l)"
        echo "WARNING: ${alertCount} alert(s) firing: ${firingAlerts}"
        details="${details}firing_alerts: ${alertCount} (${firingAlerts}); "
    else
        echo "No critical alerts firing"
        details="${details}alerts: none firing; "
    fi

    oc get nodes -o json > "${REPORT_DIR}/nodes-baseline.json" 2>/dev/null || true
    oc get co -o json > "${REPORT_DIR}/co-baseline.json" 2>/dev/null || true

    if (( failed > 0 )); then
        echo >&2 "Cluster health baseline: ${failed} issue(s) found"
        AppendCheck "cluster_health_baseline" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        echo "Cluster health baseline: all checks passed"
        AppendCheck "cluster_health_baseline" "pass" "${details}"
    fi
    true
}

# ──────────────────────────────────────────────────────────────────────
#  Check 4: MachineConfigPool readiness
# ──────────────────────────────────────────────────────────────────────
CheckMcpReadiness() {
    echo -e "\n=== Check 4: MachineConfigPool readiness ==="

    typeset failed=0 details=""

    typeset mcpIssues
    mcpIssues="$(oc get machineconfigpools --no-headers 2>/dev/null | \
        awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')" || true

    if [[ -n "${mcpIssues}" ]]; then
        echo >&2 "Unhealthy MachineConfigPools: ${mcpIssues}"
        details="unhealthy_mcps: ${mcpIssues}; "
        (( failed += 1 ))

        for mcp in ${mcpIssues}; do
            echo -e "\n### MCP ${mcp} ###"
            oc describe machineconfigpool "${mcp}" 2>/dev/null || true
        done
    else
        typeset mcpCount
        mcpCount="$(oc get machineconfigpools --no-headers 2>/dev/null | wc -l)"
        echo "All ${mcpCount} MachineConfigPools are updated and not degraded"
        details="all ${mcpCount} MCPs healthy (Updated=True, Updating=False, Degraded=False); "
    fi

    typeset mismatch=""
    while IFS= read -r line; do
        typeset mcpName ready desired
        mcpName="$(echo "${line}" | awk '{print $1}')"
        ready="$(echo "${line}" | awk '{print $7}')"
        desired="$(echo "${line}" | awk '{print $6}')"
        if [[ -n "${ready}" && -n "${desired}" && "${ready}" != "${desired}" ]]; then
            mismatch="${mismatch}${mcpName} (ready=${ready}, desired=${desired}); "
        fi
    done < <(oc get machineconfigpools --no-headers 2>/dev/null || true)

    if [[ -n "${mismatch}" ]]; then
        echo >&2 "MCP machine count mismatch: ${mismatch}"
        details="${details}machine_count_mismatch: ${mismatch}"
        (( failed += 1 ))
    fi

    oc get machineconfigpools -o json > "${REPORT_DIR}/mcp-baseline.json" 2>/dev/null || true

    if (( failed > 0 )); then
        echo >&2 "MachineConfigPool readiness: ${failed} issue(s) found"
        AppendCheck "mcp_readiness" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        echo "MachineConfigPool readiness: all checks passed"
        AppendCheck "mcp_readiness" "pass" "${details}"
    fi
    true
}

# ──────────────────────────────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────────────────────────────
Main() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    typeset target="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}"
    if [[ -z "${target}" ]]; then
        echo >&2 "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is not set; cannot determine upgrade target"
        exit 3
    fi
    echo "Target release image: ${target}"

    KUBECONFIG="" oc registry login

    typeset targetVersion targetMajor targetMinor ocpXy
    targetVersion="$(oc adm release info "${target}" --output=json | jq -r '.metadata.version')"
    targetMajor="$(echo "${targetVersion}" | cut -f1 -d.)"
    targetMinor="$(echo "${targetVersion}" | cut -f2 -d.)"
    ocpXy="${targetMajor}.${targetMinor}"
    echo "Target OCP version: ${targetVersion} (${ocpXy})"

    typeset sourceVersion
    sourceVersion="$(oc get clusterversion --no-headers | awk '{print $2}')"
    echo "Source OCP version: ${sourceVersion}"

    echo -e "\n=== Starting OPP pre-flight validation ===\n"

    InitReport

    typeset tmpFile
    tmpFile="$(mktemp)"
    jq --arg tv "${targetVersion}" --arg sv "${sourceVersion}" --arg ti "${target}" \
        '. + {"target_version": $tv, "source_version": $sv, "target_image": $ti, "timestamp": now | tostring}' \
        "${REPORT_FILE}" > "${tmpFile}" && mv "${tmpFile}" "${REPORT_FILE}"

    CheckApiDeprecations "${targetMinor}" "${ocpXy}"
    CheckOppCompatibility "${ocpXy}"
    CheckClusterHealth
    CheckMcpReadiness

    echo -e "\n=== Pre-flight summary ==="
    jq '.' "${REPORT_FILE}"

    if (( CHECKS_FAILED > 0 )); then
        echo >&2 "Pre-flight validation FAILED: ${CHECKS_FAILED} check(s) did not pass"
        echo >&2 "Review ${REPORT_FILE} for details"
        exit 3
    fi

    echo "Pre-flight validation PASSED: all checks succeeded"
    true
}

Main "$@"
