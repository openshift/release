#!/bin/bash
#
# Pre-upgrade health check on the ACM managed spoke cluster.
# Health check logic is sourced from cucushift-upgrade-prehealthcheck-commands.sh
# (ci-operator/step-registry/cucushift/upgrade/prehealthcheck/) run against the spoke kubeconfig.
#
set -euxo pipefail; shopt -s inherit_errexit

[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

typeset spokeName='spoke'
if [[ -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    spokeName="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")"
    [[ -n "${spokeName}" ]] || spokeName='spoke'
fi

WriteSpokePrehealthcheckFailureDiagnostics() {
    typeset artifactFile="${ARTIFACT_DIR}/spoke-${spokeName}-upgrade-prehealthcheck-failure.txt"
    typeset unhealthyMcp mcpName nodeName coName

    {
        echo "=== oc get clusterversion ==="
        oc get clusterversion version -o wide 2>&1 || true
        echo
        echo "=== oc describe clusterversion version ==="
        oc describe clusterversion version 2>&1 || true
        echo
        echo "=== oc get machineconfigpools ==="
        oc get machineconfigpools 2>&1 || true
        echo
        echo "=== MCP custom-columns (UPDATING/DEGRADED) ==="
        oc get machineconfigpools \
            -o 'custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?(@.type=="Updating")].status,DEGRADED:status.conditions[?(@.type=="Degraded")].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount' \
            2>&1 || true
        unhealthyMcp="$(oc get machineconfigpools \
            -o 'custom-columns=NAME:metadata.name,UPDATING:status.conditions[?(@.type=="Updating")].status,DEGRADED:status.conditions[?(@.type=="Degraded")].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount' \
            --no-headers 2>&1 | grep -Ev '[[:space:]]False[[:space:]]+False[[:space:]]+0[[:space:]]*$' || true)"
        if [[ -n "${unhealthyMcp}" ]]; then
            echo
            echo "=== oc describe unhealthy MCPs ==="
            while read -r mcpName _; do
                [[ -n "${mcpName}" ]] || continue
                echo "--- ${mcpName} ---"
                oc describe machineconfigpool "${mcpName}" 2>&1 || true
            done <<<"${unhealthyMcp}"
        fi
        echo
        echo "=== oc get nodes ==="
        oc get nodes -o wide 2>&1 || true
        echo
        echo "=== oc describe not-Ready nodes ==="
        while read -r nodeName _; do
            [[ -n "${nodeName}" ]] || continue
            echo "--- ${nodeName} ---"
            oc describe node "${nodeName}" 2>&1 || true
        done < <(oc get nodes --no-headers 2>&1 | awk '$2 != "Ready" {print $1}' || true)
        echo
        echo "=== oc get clusteroperators ==="
        oc get clusteroperators 2>&1 || true
        echo
        echo "=== oc describe unhealthy clusteroperators ==="
        while read -r coName _; do
            [[ -n "${coName}" ]] || continue
            echo "--- ${coName} ---"
            oc describe clusteroperator "${coName}" 2>&1 || true
        done < <(oc get clusteroperators --no-headers 2>&1 | awk '$3 == "False" || $4 == "True" || $5 == "True" {print $1}' || true)
        echo
        echo "=== oc get pods -n openshift-machine-config-operator ==="
        oc get pods -n openshift-machine-config-operator -o wide 2>&1 || true
    } > "${artifactFile}"
    : "Wrote spoke upgrade prehealthcheck diagnostics to ${artifactFile}"
    true
}

SpokePrehealthcheckFailureCleanup() {
    typeset -i ret=$?
    if (( ret != 0 )); then
        WriteSpokePrehealthcheckFailureDiagnostics || true
    fi
    return "${ret}"
}
trap SpokePrehealthcheckFailureCleanup EXIT

function run_command_oc() {
    typeset -i try=0 max=40; typeset ret_val

    if [[ "$#" -lt 1 ]]; then
        return 0
    fi

    while (( try < max )); do
        if ret_val=$(oc "$@" 2>&1); then
            break
        fi
        (( try += 1 ))
        sleep 3
    done

    if (( try == max )); then
        echo >&2 "Run:[oc $*]"
        echo >&2 "Get:[$ret_val]"
        return 255
    fi

    echo "${ret_val}"
}

function check_clusteroperators() {
    typeset -i tmp_ret=0; typeset coOutput input column last_column_name rc null_version unavailable_operator degraded_operator

    : "Make sure every operator does not report empty column"
    coOutput="$(${OC} get clusteroperator)"
    input="${coOutput}"
    column=$(head -n 1 <<< "${coOutput}" | awk '{print NF}')
    last_column_name=$(head -n 1 <<< "${coOutput}" | awk '{print $NF}')
    if [[ ${last_column_name} == "MESSAGE" ]]; then
        (( column -= 1 ))
        input="$(awk -v end=${column} '{for(i=1;i<=end;i++) printf $i"\t"; print ""}' <<< "${coOutput}")"
    fi

    while IFS= read -r line
    do
        rc=$(echo "${line}" | awk '{print NF}')
        if (( rc != column )); then
            echo >&2 "The following line have empty column"
            echo >&2 "${line}"
            (( tmp_ret += 1 ))
        fi
    done <<< "${input}"

    : "Make sure every operator column reports version"
    if null_version=$(${OC} get clusteroperator -o json | jq '.items[] | select(.status.versions == null) | .metadata.name') && [[ ${null_version} != "" ]]; then
        echo >&2 "Null Version: ${null_version}"
        (( tmp_ret += 1 ))
    fi

    : "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(${OC} get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o jsonpath='{.items[].status.conditions[?(@.type=="Available")].status}'| grep -iv "True"; then
        echo >&2 "Some operators are unavailable, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    : "Make sure every operator's PROGRESSING column is False"
    if progressing_operator=$(${OC} get clusteroperator | awk '$4 == "True"' | grep "True"); then
        echo >&2 "Some operator's PROGRESSING is True"
        echo >&2 "$progressing_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Progressing") | .status' | grep -iv "False"; then
        echo >&2 "Some operators are Progressing, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    : "Make sure every operator's DEGRADED column is False"
    if degraded_operator=$(${OC} get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    if ${OC} get clusteroperator -o jsonpath='{.items[].status.conditions[?(@.type=="Degraded")].status}'| grep -iv 'False'; then
        echo >&2 "Some operators are Degraded, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    return $tmp_ret
}

function wait_clusteroperators_continous_success() {
    typeset -i continuousSuccessfulCheck=0 passedCriteria=3
    typeset -i wMax=$(( ACM_SPOKE_PRE_CO_READY_TIMEOUT_MINUTES * 60 )) wInt=60
    SECONDS=0
    while (( SECONDS < wMax && continuousSuccessfulCheck < passedCriteria )); do
        : "Checking CO status (${SECONDS}/${wMax}s, consecutive pass ${continuousSuccessfulCheck}/${passedCriteria})"
        if check_clusteroperators; then
            (( continuousSuccessfulCheck += 1 ))
        else
            : "cluster operators not ready yet, waiting (${SECONDS}/${wMax}s)"
            continuousSuccessfulCheck=0
        fi
        sleep "${wInt}"
    done
    if (( continuousSuccessfulCheck < passedCriteria )); then
        echo >&2 "Some cluster operator does not get ready or not stable"
        oc get co
        return 1
    fi
    : "All cluster operators status check PASSED"
}

function check_mcp() {
    typeset updating_mcp unhealthy_mcp mcpUpdatingOutput mcpFullOutput unhealthy_mcp_names mcp_name

    mcpUpdatingOutput="$(oc get machineconfigpools \
        -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status \
        --no-headers 2>&1 || true)"
    if [[ -n "${mcpUpdatingOutput}" ]]; then
        updating_mcp=$(grep -v "False" <<< "${mcpUpdatingOutput}" || true)
        if [[ -n "${updating_mcp}" ]]; then
            : "Some mcp is updating"
            echo "${updating_mcp}"
            return 1
        fi
    else
        : "Did not run 'oc get machineconfigpools' successfully"
        return 1
    fi

    mcpFullOutput="$(oc get machineconfigpools \
        -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount \
        --no-headers 2>&1 || true)"
    if [[ -n "${mcpFullOutput}" ]]; then
        unhealthy_mcp=$(grep -v "False.*False.*0" <<< "${mcpFullOutput}" || true)
        if [[ -n "${unhealthy_mcp}" ]]; then
            : "Detected unhealthy mcp"
            echo "${unhealthy_mcp}"
            oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount | grep -v "False.*False.*0"
            oc get machineconfigpools
            unhealthy_mcp_names=$(echo "${unhealthy_mcp}" | awk '{print $1}')
            while read -r mcp_name; do
                [[ -n "${mcp_name}" ]] || continue
                : "Name: ${mcp_name}"
                oc describe mcp "${mcp_name}" || echo >&2 "oc describe mcp ${mcp_name} failed"
            done <<< "${unhealthy_mcp_names}"
            return 2
        fi
    else
        : "Did not run 'oc get machineconfigpools' successfully"
        return 1
    fi
    return 0
}

function wait_mcp_continous_success() {
    typeset -i nodeCount wMax wInt=30
    typeset -i continuousSuccessfulCheck=0 passedCriteria=10  # 5 min × 60 s ÷ 30 s interval
    typeset -i continuousDegradedCheck=0 degradedCriteria=5
    typeset -i ret=0
    nodeCount="$(oc get node -o json | jq '.items | length')"
    wMax=$(( nodeCount * 20 * 60 ))  # nodes × 20 min × 60 s
    SECONDS=0
    while (( SECONDS < wMax && continuousSuccessfulCheck < passedCriteria )); do
        : "Checking MCP status (${SECONDS}/${wMax}s, consecutive pass ${continuousSuccessfulCheck}/${passedCriteria})"
        ret=0
        check_mcp || ret=$?
        if [[ "${ret}" == "0" ]]; then
            continuousDegradedCheck=0
            (( continuousSuccessfulCheck += 1 ))
        elif [[ "${ret}" == "1" ]]; then
            : "Some machines are updating, waiting (${SECONDS}/${wMax}s)"
            continuousSuccessfulCheck=0
            continuousDegradedCheck=0
        else
            continuousSuccessfulCheck=0
            : "Some machines are degraded (${continuousDegradedCheck}/${degradedCriteria}), waiting (${SECONDS}/${wMax}s)"
            (( continuousDegradedCheck += 1 ))
            if (( continuousDegradedCheck >= degradedCriteria )); then
                break
            fi
        fi
        sleep "${wInt}"
    done
    if (( continuousSuccessfulCheck < passedCriteria )); then
        echo >&2 "Some mcp does not get ready or not stable"
        oc get machineconfigpools
        return 1
    fi
    : "All mcp status check PASSED"
}

function check_node() {
    typeset -i node_number ready_number
    node_number=$(oc get node -o json | jq '.items | length')
    ready_number=$(oc get node -o json | jq '[.items[] | select(
        any(.status.conditions[]; .type == "Ready" and .status == "True")
    )] | length')
    if (( node_number == ready_number )); then
        : "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node -o json | jq -r '.items[] |
                select(any(.status.conditions[]; .type == "Ready" and .status == "True") | not) |
                .metadata.name'
        fi
        return 1
    fi
}

function check_pod() {
    : "Show all pods status for reference/debug"
    oc get pods --all-namespaces
}

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

OC="run_command_oc"

oc get machineconfig

: "Step #1: Make sure no degraded or updating mcp"
wait_mcp_continous_success

: "Step #2: check all cluster operators get stable and ready"
wait_clusteroperators_continous_success

: "Step #3: Make sure every machine is in 'Ready' status"
check_node

: "Step #4: check all pods are in status running or complete"
check_pod

true
