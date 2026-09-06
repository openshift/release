#!/bin/bash

set -eux -o pipefail
shopt -s inherit_errexit

OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    set +x
    source "${SHARED_DIR}/proxy-conf.sh"
    set -x
fi

REPORT_DIR="${ARTIFACT_DIR}/preflight"
REPORT_FILE="${REPORT_DIR}/preflight-report.json"
mkdir -p "${REPORT_DIR}"

typeset -i CHECKS_FAILED=0
typeset -i EXIT_CODE=0

function DebugOnExit () {
    if (( EXIT_CODE != 0 )); then
        : "### DEBUG: Pre-flight failure diagnostics ###"
        : "# ClusterVersion"
        oc get clusterversion 2>/dev/null || : "unavailable"
        : "# ClusterOperators"
        oc get co 2>/dev/null || : "unavailable"
        : "# MachineConfigPools"
        oc get machineconfigpools 2>/dev/null || : "unavailable"
        : "# Nodes"
        oc get nodes 2>/dev/null || : "unavailable"
        : "# OPP Operator CSVs"
        oc get csv -A 2>/dev/null || : "unavailable"
        if [[ -f "${REPORT_FILE}" ]]; then
            : "# Pre-flight report:"
            cat "${REPORT_FILE}"
        fi
    fi
    true
}

trap '{ EXIT_CODE=$?; DebugOnExit; true; }' EXIT
trap '{ EXIT_CODE=143; DebugOnExit; trap - EXIT; exit 143; }' TERM

# ──────────────────────────────────────────────────────────────────────
#  Known removed / deprecated APIs per OCP minor version.
#  Each entry lists the API group/version and the resource kind that
#  was removed IN that minor version (i.e. no longer available).
#  Source: Kubernetes deprecation guide + OCP release notes.
# ──────────────────────────────────────────────────────────────────────
typeset -A REMOVED_APIS
REMOVED_APIS["12"]="batch/v1beta1/CronJob policy/v1beta1/PodDisruptionBudget policy/v1beta1/PodSecurityPolicy discovery.k8s.io/v1beta1/EndpointSlice events.k8s.io/v1beta1/Event autoscaling/v2beta1/HorizontalPodAutoscaler"
REMOVED_APIS["14"]="storage.k8s.io/v1beta1/CSIStorageCapacity"
REMOVED_APIS["17"]="flowcontrol.apiserver.k8s.io/v1beta2/FlowSchema flowcontrol.apiserver.k8s.io/v1beta2/PriorityLevelConfiguration"
REMOVED_APIS["18"]="flowcontrol.apiserver.k8s.io/v1beta3/FlowSchema flowcontrol.apiserver.k8s.io/v1beta3/PriorityLevelConfiguration"

# ──────────────────────────────────────────────────────────────────────
#  OPP operator compatibility matrix.
#  Maps OCP minor version to minimum required operator major.minor.
#  Format: "operator_csv_prefix:min_major.min_minor"
# ──────────────────────────────────────────────────────────────────────
typeset -A OPP_COMPAT
OPP_COMPAT["4.14"]="advanced-cluster-management:2.9 rhacs-operator:4.3 odf-operator:4.14 quay-operator:3.10"
OPP_COMPAT["4.15"]="advanced-cluster-management:2.10 rhacs-operator:4.4 odf-operator:4.15 quay-operator:3.11"
OPP_COMPAT["4.16"]="advanced-cluster-management:2.11 rhacs-operator:4.5 odf-operator:4.16 quay-operator:3.12"
OPP_COMPAT["4.17"]="advanced-cluster-management:2.12 rhacs-operator:4.6 odf-operator:4.17 quay-operator:3.13"
OPP_COMPAT["4.18"]="advanced-cluster-management:2.13 rhacs-operator:4.7 odf-operator:4.18 quay-operator:3.14"
OPP_COMPAT["4.19"]="advanced-cluster-management:2.13 rhacs-operator:4.8 odf-operator:4.19 quay-operator:3.14"
OPP_COMPAT["4.20"]="advanced-cluster-management:2.14 rhacs-operator:4.9 odf-operator:4.20 quay-operator:3.15"
OPP_COMPAT["4.21"]="advanced-cluster-management:2.15 rhacs-operator:4.10 odf-operator:4.21 quay-operator:3.15"
OPP_COMPAT["4.22"]="advanced-cluster-management:2.17 rhacs-operator:4.11 odf-operator:4.21 quay-operator:3.16"
OPP_COMPAT["5.0"]="advanced-cluster-management:2.17 quay-operator:3.17 odf-operator:5.0 rhacs-operator:4.11"
OPP_COMPAT["5.1"]="advanced-cluster-management:2.17 quay-operator:3.18 odf-operator:5.1 rhacs-operator:4.12"

function InitReport () {
    cat > "${REPORT_FILE}" <<'EOFJSON'
{
  "preflight_checks": []
}
EOFJSON
    true
}

function AppendCheck () {
    typeset checkName="${1}" checkStatus="${2}" checkDetails="${3}"
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
data['preflight_checks'].append({'check': sys.argv[2], 'status': sys.argv[3], 'details': sys.argv[4]})
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "${REPORT_FILE}" "${checkName}" "${checkStatus}" "${checkDetails}"
    true
}

function CheckApiDeprecations () {
    : "=== Check 1: API deprecation scan ==="

    typeset targetMinor="${1}"
    typeset ocpDisplay="${2:-4.${targetMinor}}"
    typeset targetMajor="${ocpDisplay%%.*}"
    typeset flagged="" foundCount=0

    typeset clusterApis
    clusterApis="$(oc api-resources --no-headers)" || {
        : "WARNING: Failed to list API resources"
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
        : "WARNING: Found ${foundCount} deprecated API(s) still in use"
        echo -e "${flagged}"
        AppendCheck "api_deprecation_scan" "warn" "Found ${foundCount} deprecated API(s) in use: ${flagged}"
    else
        : "No deprecated APIs detected for target version ${ocpDisplay}"
        AppendCheck "api_deprecation_scan" "pass" "No deprecated APIs detected for ${ocpDisplay}"
    fi
    true
}

function CheckOppCompatibility () {
    : "=== Check 2: OPP operator compatibility matrix ==="

    typeset ocpKey="${1}"
    typeset compatSpec="${OPP_COMPAT[${ocpKey}]:-}"
    typeset allCsvs
    typeset failed=0

    allCsvs="$(oc get csv -A --no-headers)" || {
        : "Failed to retrieve CSVs"
        AppendCheck "opp_compatibility_matrix" "fail" "Could not list CSVs"
        (( CHECKS_FAILED += 1 ))
        return 0
    }

    if [[ -z "${compatSpec}" ]]; then
        : "No compatibility matrix entry for OCP ${ocpKey}; skipping version check"
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
            : "Operator not found: ${opPrefix}"
            details="${details}${opPrefix}: NOT INSTALLED; "
            (( failed += 1 ))
            continue
        fi

        csvName="$(echo "${csvLine}" | awk '{print $2}')"
        installedVersion="$(echo "${csvName}" | grep -oE '[0-9]+\.[0-9]+' | head -1)" || true
        if [[ -z "${installedVersion}" ]]; then
            : "Operator ${opPrefix}: could not parse version from CSV ${csvName}"
            details="${details}${opPrefix}: version unparseable from ${csvName}; "
            (( failed += 1 ))
            continue
        fi

        typeset instMajor instMinor
        instMajor="${installedVersion%%.*}"
        instMinor="${installedVersion##*.}"

        if (( instMajor < minMajor || (instMajor == minMajor && instMinor < minMinor) )); then
            : "Operator ${opPrefix} version ${installedVersion} is below minimum ${minVersion} for OCP ${ocpKey}"
            details="${details}${opPrefix}: ${installedVersion} < ${minVersion} (INCOMPATIBLE); "
            (( failed += 1 ))
        else
            : "Operator ${opPrefix}: version ${installedVersion} >= ${minVersion} (OK)"
            details="${details}${opPrefix}: ${installedVersion} >= ${minVersion} (OK); "
        fi
    done

    if (( failed > 0 )); then
        : "${failed} operator(s) failed compatibility check"
        AppendCheck "opp_compatibility_matrix" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        : "All OPP operators are compatible with OCP ${ocpKey}"
        AppendCheck "opp_compatibility_matrix" "pass" "${details}"
    fi
    true
}

function CheckClusterHealth () {
    : "=== Check 3: Cluster health baseline ==="

    typeset failed=0 details=""

    : "Checking node health..."
    typeset unreadyNodes
    if ! unreadyNodes="$(oc get node --no-headers | awk '$2 != "Ready" {print $1}')"; then
        : "Failed to query nodes"
        details="${details}nodes: query failed; "
        (( failed += 1 ))
    elif [[ -n "${unreadyNodes}" ]]; then
        : "Not-Ready nodes: ${unreadyNodes}"
        details="${details}unready_nodes: ${unreadyNodes}; "
        (( failed += 1 ))
    else
        typeset nodeCount
        nodeCount="$(oc get node --no-headers | wc -l)"
        : "All ${nodeCount} nodes Ready"
        details="${details}nodes: all ${nodeCount} ready; "
    fi

    : "Checking ClusterOperator health..."
    typeset unhealthyCo
    if ! unhealthyCo="$(oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')"; then
        : "Failed to query ClusterOperators"
        details="${details}cluster_operators: query failed; "
        (( failed += 1 ))
    elif [[ -n "${unhealthyCo}" ]]; then
        : "Unhealthy ClusterOperators: ${unhealthyCo}"
        details="${details}unhealthy_co: ${unhealthyCo}; "
        (( failed += 1 ))
    else
        : "All ClusterOperators healthy"
        details="${details}cluster_operators: all healthy; "
    fi

    : "Checking ClusterVersion conditions..."
    typeset avail progressing degraded
    avail="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" || true
    progressing="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" || true
    degraded="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')" || true
    if [[ "${avail}" != "True" || ( -n "${progressing}" && "${progressing}" != "False" ) || ( -n "${degraded}" && "${degraded}" != "False" ) ]]; then
        : "CVO health check failed: Available=${avail} Progressing=${progressing} Degraded=${degraded}"
        details="${details}cvo: Available=${avail} Progressing=${progressing} Degraded=${degraded}; "
        (( failed += 1 ))
    else
        : "CVO: Available=True, Progressing=False, Degraded=False"
        details="${details}cvo: healthy; "
    fi

    : "Checking for firing alerts..."
    typeset firingAlerts=""
    if ! firingAlerts="$(oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
        curl -s 'http://localhost:9090/api/v1/alerts' | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('status') != 'success':
    print('query returned non-success status', file=sys.stderr)
    sys.exit(1)
alerts = data.get('data', {}).get('alerts', [])
names = sorted(set(
    a['labels']['alertname'] for a in alerts
    if a.get('state') == 'firing'
    and a.get('labels', {}).get('alertname') not in ('Watchdog', 'AlertmanagerReceiversNotConfigured')
))
print('\n'.join(names))
")"; then
        : "Alert query failed or unavailable"
        details="${details}alerts: query failed; "
    elif [[ -n "${firingAlerts}" ]]; then
        typeset alertCount
        alertCount="$(echo "${firingAlerts}" | wc -l)"
        : "WARNING: ${alertCount} alert(s) firing: ${firingAlerts}"
        details="${details}firing_alerts: ${alertCount} (${firingAlerts}); "
    else
        : "No critical alerts firing"
        details="${details}alerts: none firing; "
    fi

    oc get nodes -o json > "${REPORT_DIR}/nodes-baseline.json" 2>/dev/null || true
    oc get co -o json > "${REPORT_DIR}/co-baseline.json" 2>/dev/null || true

    if (( failed > 0 )); then
        : "Cluster health baseline: ${failed} issue(s) found"
        AppendCheck "cluster_health_baseline" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        : "Cluster health baseline: all checks passed"
        AppendCheck "cluster_health_baseline" "pass" "${details}"
    fi
    true
}

function CheckMcpReadiness () {
    : "=== Check 4: MachineConfigPool readiness ==="

    typeset failed=0 details=""

    typeset mcpRaw=""
    if ! mcpRaw="$(oc get machineconfigpools --no-headers 2>&1)"; then
        : "Failed to query MachineConfigPools"
        details="machineconfigpools: query failed; "
        (( failed += 1 ))
    else
        typeset mcpIssues=""
        mcpIssues="$(echo "${mcpRaw}" | \
            awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')" || true

        if [[ -n "${mcpIssues}" ]]; then
            : "Unhealthy MachineConfigPools: ${mcpIssues}"
            details="unhealthy_mcps: ${mcpIssues}; "
            (( failed += 1 ))

            for mcp in ${mcpIssues}; do
                : "### MCP ${mcp} ###"
                oc describe machineconfigpool "${mcp}" || true
            done
        else
            typeset mcpCount
            mcpCount="$(echo "${mcpRaw}" | wc -l)"
            : "All ${mcpCount} MachineConfigPools are updated and not degraded"
            details="all ${mcpCount} MCPs healthy (Updated=True, Updating=False, Degraded=False); "
        fi
    fi

    typeset mismatch=""
    if [[ -n "${mcpRaw:-}" ]]; then
        while IFS= read -r line; do
            typeset mcpName ready desired
            mcpName="$(echo "${line}" | awk '{print $1}')"
            ready="$(echo "${line}" | awk '{print $7}')"
            desired="$(echo "${line}" | awk '{print $6}')"
            if [[ -n "${ready}" && -n "${desired}" && "${ready}" != "${desired}" ]]; then
                mismatch="${mismatch}${mcpName} (ready=${ready}, desired=${desired}); "
            fi
        done <<< "${mcpRaw}"
    fi

    if [[ -n "${mismatch}" ]]; then
        : "MCP machine count mismatch: ${mismatch}"
        details="${details}machine_count_mismatch: ${mismatch}"
        (( failed += 1 ))
    fi

    oc get machineconfigpools -o json > "${REPORT_DIR}/mcp-baseline.json" 2>/dev/null || true

    if (( failed > 0 )); then
        : "MachineConfigPool readiness: ${failed} issue(s) found"
        AppendCheck "mcp_readiness" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        : "MachineConfigPool readiness: all checks passed"
        AppendCheck "mcp_readiness" "pass" "${details}"
    fi
    true
}

function Main () {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    typeset target="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}"
    if [[ -z "${target}" ]]; then
        : "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is not set; cannot determine upgrade target"
        exit 3
    fi
    : "Target release image: ${target}"

    set +x
    KUBECONFIG="" oc registry login
    set -x

    typeset targetVersion targetMajor targetMinor ocpXy
    targetVersion="$(oc adm release info "${target}" -o jsonpath='{.metadata.version}')"
    targetMajor="$(echo "${targetVersion}" | cut -f1 -d.)"
    targetMinor="$(echo "${targetVersion}" | cut -f2 -d.)"
    ocpXy="${targetMajor}.${targetMinor}"
    : "Target OCP version: ${targetVersion} (${ocpXy})"

    typeset sourceVersion
    sourceVersion="$(oc get clusterversion --no-headers | awk '{print $2}')"
    : "Source OCP version: ${sourceVersion}"

    : "=== Starting OPP pre-flight validation ==="

    InitReport

    python3 -c "
import json, sys, time
with open(sys.argv[1]) as f:
    data = json.load(f)
data['target_version'] = sys.argv[2]
data['source_version'] = sys.argv[3]
data['target_image'] = sys.argv[4]
data['timestamp'] = str(time.time())
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "${REPORT_FILE}" "${targetVersion}" "${sourceVersion}" "${target}"

    CheckApiDeprecations "${targetMinor}" "${ocpXy}"
    CheckOppCompatibility "${ocpXy}"
    CheckClusterHealth
    CheckMcpReadiness

    : "=== Pre-flight summary ==="
    python3 -m json.tool "${REPORT_FILE}"

    if (( CHECKS_FAILED > 0 )); then
        : "Pre-flight validation FAILED: ${CHECKS_FAILED} check(s) did not pass"
        : "Review ${REPORT_FILE} for details"
        exit 3
    fi

    : "Pre-flight validation PASSED: all checks succeeded"
    true
}

Main "$@"
