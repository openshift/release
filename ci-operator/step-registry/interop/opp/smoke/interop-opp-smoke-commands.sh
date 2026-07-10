#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ---------------------------------------------------------------------------
# OPP post-upgrade smoke tests
#
# Validates that OPP bundle components (ACM, ACS, ODF, Quay) are healthy
# after an OCP upgrade.  Produces JUnit XML consumed by Prow / Sippy /
# TestGrid.
# ---------------------------------------------------------------------------

OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"
SMOKE_SETTLE_SECONDS="${SMOKE_SETTLE_SECONDS:-120}"

JUNIT_FILE="${ARTIFACT_DIR}/junit_opp_smoke.xml"

# Accumulators for JUnit generation
declare -a TC_NAMES=()
declare -a TC_RESULTS=()   # "pass" or "fail"
declare -a TC_MESSAGES=()  # failure message (empty when pass)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

add_result() {
    local name="$1" result="$2" message="${3:-}"
    TC_NAMES+=("$name")
    TC_RESULTS+=("$result")
    TC_MESSAGES+=("$message")
}

xml_escape() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&apos;}"
    printf '%s' "$text"
}

write_junit() {
    local total=${#TC_NAMES[@]}
    local failures=0
    for r in "${TC_RESULTS[@]}"; do
        if [[ "$r" == "fail" ]]; then
            (( failures++ )) || true
        fi
    done

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"opp-smoke\" tests=\"${total}\" failures=\"${failures}\">"
        for i in "${!TC_NAMES[@]}"; do
            local name
            name="$(xml_escape "${TC_NAMES[$i]}")"
            echo "  <testcase classname=\"opp-smoke\" name=\"${name}\">"
            if [[ "${TC_RESULTS[$i]}" == "fail" ]]; then
                local msg
                msg="$(xml_escape "${TC_MESSAGES[$i]}")"
                echo "    <failure message=\"${msg}\"></failure>"
            fi
            echo "  </testcase>"
        done
        echo "</testsuite>"
    } > "${JUNIT_FILE}"
    echo "JUnit XML written to ${JUNIT_FILE}"
}

# shellcheck disable=SC2317  # invoked via trap
collect_exit_artifacts() {
    echo "Collecting exit diagnostics..."
    oc get clusteroperators -o yaml > "${ARTIFACT_DIR}/clusteroperators.yaml" 2>/dev/null || true
    oc get csv --all-namespaces -o yaml > "${ARTIFACT_DIR}/csvs.yaml" 2>/dev/null || true
    oc get nodes -o yaml > "${ARTIFACT_DIR}/nodes.yaml" 2>/dev/null || true
}

trap collect_exit_artifacts EXIT

# ---------------------------------------------------------------------------
# Test 1: cluster-health
# ---------------------------------------------------------------------------

test_cluster_health() {
    echo -e "\n=== Test: cluster-health ==="
    local fail_msg=""

    # ClusterOperators: Available=True, Degraded!=True
    local co_problems
    co_problems="$(oc get clusteroperators -o json | jq -r '
        .items[]
        | select(
            (.status.conditions // [] | map(select(.type=="Available")) | first | .status) != "True"
            or
            (.status.conditions // [] | map(select(.type=="Degraded")) | first | .status) == "True"
        )
        | .metadata.name
    ')" || true

    if [[ -n "$co_problems" ]]; then
        fail_msg="Unhealthy ClusterOperators: ${co_problems//$'\n'/, }"
        echo "FAIL: ${fail_msg}"
    else
        echo "PASS: All ClusterOperators healthy"
    fi

    # Nodes: all Ready
    local node_problems
    node_problems="$(oc get nodes -o json | jq -r '
        .items[]
        | select(
            (.status.conditions // [] | map(select(.type=="Ready")) | first | .status) != "True"
        )
        | .metadata.name
    ')" || true

    if [[ -n "$node_problems" ]]; then
        local node_msg="Not-Ready nodes: ${node_problems//$'\n'/, }"
        if [[ -n "$fail_msg" ]]; then
            fail_msg="${fail_msg}; ${node_msg}"
        else
            fail_msg="$node_msg"
        fi
        echo "FAIL: ${node_msg}"
    else
        echo "PASS: All nodes Ready"
    fi

    # ClusterVersion: Available=True
    local cv_available
    cv_available="$(oc get clusterversion version -o json | jq -r '
        .status.conditions // [] | map(select(.type=="Available")) | first | .status
    ')" || true

    if [[ "$cv_available" != "True" ]]; then
        local cv_msg="ClusterVersion Available=${cv_available:-unknown}"
        if [[ -n "$fail_msg" ]]; then
            fail_msg="${fail_msg}; ${cv_msg}"
        else
            fail_msg="$cv_msg"
        fi
        echo "FAIL: ${cv_msg}"
    else
        echo "PASS: ClusterVersion Available=True"
    fi

    if [[ -z "$fail_msg" ]]; then
        add_result "cluster-health" "pass"
    else
        add_result "cluster-health" "fail" "$fail_msg"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: opp-operators
# ---------------------------------------------------------------------------

test_opp_operators() {
    echo -e "\n=== Test: opp-operators ==="
    local fail_msg=""

    IFS=',' read -ra operators <<< "$OPP_OPERATORS"
    for op in "${operators[@]}"; do
        op="$(echo "$op" | xargs)"  # trim whitespace
        echo "Checking operator: ${op}"

        # Find CSV matching this operator prefix
        local csv_info
        csv_info="$(oc get csv --all-namespaces -o json | jq -r --arg prefix "$op" '
            .items[]
            | select(.metadata.name | startswith($prefix))
            | "\(.metadata.namespace)/\(.metadata.name)/\(.status.phase)"
        ' | head -1)" || true

        if [[ -z "$csv_info" ]]; then
            local msg="CSV not found for ${op}"
            echo "FAIL: ${msg}"
            if [[ -n "$fail_msg" ]]; then
                fail_msg="${fail_msg}; ${msg}"
            else
                fail_msg="$msg"
            fi
            continue
        fi

        local csv_ns csv_name csv_phase
        csv_ns="$(echo "$csv_info" | cut -d/ -f1)"
        csv_name="$(echo "$csv_info" | cut -d/ -f2)"
        csv_phase="$(echo "$csv_info" | cut -d/ -f3)"

        if [[ "$csv_phase" != "Succeeded" ]]; then
            local msg="CSV ${csv_name} in phase ${csv_phase} (expected Succeeded)"
            echo "FAIL: ${msg}"
            if [[ -n "$fail_msg" ]]; then
                fail_msg="${fail_msg}; ${msg}"
            else
                fail_msg="$msg"
            fi
        else
            echo "PASS: CSV ${csv_name} phase=Succeeded"
        fi

        # Check pods are Ready in the operator namespace (with settling window)
        echo "Waiting ${SMOKE_SETTLE_SECONDS}s settling window for pods in ${csv_ns}..."
        sleep "${SMOKE_SETTLE_SECONDS}"

        local not_ready_pods
        not_ready_pods="$(oc get pods -n "$csv_ns" -o json | jq -r '
            .items[]
            | select(.status.phase != "Succeeded")
            | select(
                (.status.containerStatuses // [] | map(select(.ready != true)) | length) > 0
            )
            | .metadata.name
        ')" || true

        if [[ -n "$not_ready_pods" ]]; then
            local msg="Not-ready pods in ${csv_ns}: ${not_ready_pods//$'\n'/, }"
            echo "FAIL: ${msg}"
            if [[ -n "$fail_msg" ]]; then
                fail_msg="${fail_msg}; ${msg}"
            else
                fail_msg="$msg"
            fi
        else
            echo "PASS: All pods ready in ${csv_ns}"
        fi
    done

    if [[ -z "$fail_msg" ]]; then
        add_result "opp-operators" "pass"
    else
        add_result "opp-operators" "fail" "$fail_msg"
    fi
}

# ---------------------------------------------------------------------------
# Test 3: acm-connectivity
# ---------------------------------------------------------------------------

test_acm_connectivity() {
    echo -e "\n=== Test: acm-connectivity ==="
    local fail_msg=""

    # Check if ManagedCluster resources exist
    local mc_count
    mc_count="$(oc get managedclusters --no-headers 2>/dev/null | wc -l)" || true

    if [[ "$mc_count" -eq 0 ]]; then
        echo "SKIP: No ManagedCluster resources found"
        add_result "acm-connectivity" "pass" ""
        return
    fi

    local mc_problems
    mc_problems="$(oc get managedclusters -o json | jq -r '
        .items[]
        | select(
            (.status.conditions // [] | map(select(.type=="ManagedClusterConditionAvailable")) | first | .status) != "True"
        )
        | .metadata.name
    ')" || true

    if [[ -n "$mc_problems" ]]; then
        fail_msg="ManagedClusters not available: ${mc_problems//$'\n'/, }"
        echo "FAIL: ${fail_msg}"
    else
        echo "PASS: All ManagedClusters available"
    fi

    if [[ -z "$fail_msg" ]]; then
        add_result "acm-connectivity" "pass"
    else
        add_result "acm-connectivity" "fail" "$fail_msg"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: acs-sensors
# ---------------------------------------------------------------------------

test_acs_sensors() {
    echo -e "\n=== Test: acs-sensors ==="
    local fail_msg=""

    # Check SecuredCluster CR status first
    local sc_status
    sc_status="$(oc get securedclusters.platform.stackrox.io --all-namespaces -o json 2>/dev/null | jq -r '
        .items[]
        | "\(.metadata.namespace)/\(.metadata.name)/\(.status.conditions // [] | map(select(.type=="Deployed" or .type=="Initialized")) | map(.status) | join(","))"
    ' | head -1)" || true

    if [[ -n "$sc_status" ]]; then
        local sc_ns sc_name sc_conds
        sc_ns="$(echo "$sc_status" | cut -d/ -f1)"
        sc_name="$(echo "$sc_status" | cut -d/ -f2)"
        sc_conds="$(echo "$sc_status" | cut -d/ -f3)"
        echo "SecuredCluster ${sc_name} in ${sc_ns}: conditions=${sc_conds}"

        # Verify sensor pods are Running in the SecuredCluster namespace
        local sensor_status
        sensor_status="$(oc get pods -n "$sc_ns" -l app=sensor -o json 2>/dev/null | jq -r '
            .items[] | "\(.metadata.name):\(.status.phase)"
        ')" || true

        if [[ -z "$sensor_status" ]]; then
            fail_msg="No sensor pods found in ${sc_ns}"
            echo "FAIL: ${fail_msg}"
        else
            local bad_sensors
            bad_sensors="$(echo "$sensor_status" | grep -v ':Running$' || true)"
            if [[ -n "$bad_sensors" ]]; then
                fail_msg="Sensor pods not running: ${bad_sensors//$'\n'/, }"
                echo "FAIL: ${fail_msg}"
            else
                echo "PASS: Sensor pods running in ${sc_ns}"
            fi
        fi
    else
        # No SecuredCluster CR; check if ACS operator is even installed
        local acs_csv
        acs_csv="$(oc get csv --all-namespaces -o json 2>/dev/null | jq -r '
            .items[] | select(.metadata.name | startswith("rhacs-operator")) | .metadata.name
        ' | head -1)" || true

        if [[ -z "$acs_csv" ]]; then
            echo "SKIP: ACS operator not installed"
            add_result "acs-sensors" "pass" ""
            return
        fi

        # ACS operator installed but no SecuredCluster CR
        echo "SKIP: ACS operator installed but no SecuredCluster CR found"
        add_result "acs-sensors" "pass" ""
        return
    fi

    if [[ -z "$fail_msg" ]]; then
        add_result "acs-sensors" "pass"
    else
        add_result "acs-sensors" "fail" "$fail_msg"
    fi
}

# ---------------------------------------------------------------------------
# Test 5: quay-pull
# ---------------------------------------------------------------------------

test_quay_pull() {
    echo -e "\n=== Test: quay-pull ==="
    local fail_msg=""

    # Find the Quay registry route
    local quay_route
    quay_route="$(oc get routes --all-namespaces -o json 2>/dev/null | jq -r '
        .items[]
        | select(.metadata.name | test("quay"; "i"))
        | select(.spec.host | test("quay"; "i"))
        | .spec.host
    ' | head -1)" || true

    if [[ -z "$quay_route" ]]; then
        # Try looking for QuayRegistry CR to find the route
        quay_route="$(oc get quayregistries.quay.redhat.com --all-namespaces -o json 2>/dev/null | jq -r '
            .items[0].status.registryEndpoint // empty
        ' | sed 's|^https://||')" || true
    fi

    if [[ -z "$quay_route" ]]; then
        # Check if Quay operator is even installed
        local quay_csv
        quay_csv="$(oc get csv --all-namespaces -o json 2>/dev/null | jq -r '
            .items[] | select(.metadata.name | startswith("quay-operator")) | .metadata.name
        ' | head -1)" || true

        if [[ -z "$quay_csv" ]]; then
            echo "SKIP: Quay operator not installed"
            add_result "quay-pull" "pass" ""
            return
        fi

        fail_msg="Quay operator installed but no registry route found"
        echo "FAIL: ${fail_msg}"
        add_result "quay-pull" "fail" "$fail_msg"
        return
    fi

    echo "Found Quay route: ${quay_route}"

    # Attempt to pull the Quay health endpoint (API check instead of image pull
    # since we may not have registry credentials configured)
    local http_code
    http_code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${quay_route}/api/v1/discovery" --max-time 30)" || true

    if [[ "$http_code" =~ ^(200|401|403)$ ]]; then
        echo "PASS: Quay registry responding (HTTP ${http_code}) at ${quay_route}"
    else
        fail_msg="Quay registry unreachable at ${quay_route} (HTTP ${http_code:-timeout})"
        echo "FAIL: ${fail_msg}"
    fi

    if [[ -z "$fail_msg" ]]; then
        add_result "quay-pull" "pass"
    else
        add_result "quay-pull" "fail" "$fail_msg"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    echo "OPP Smoke Tests starting"
    echo "Operators: ${OPP_OPERATORS}"
    echo "Settle window: ${SMOKE_SETTLE_SECONDS}s"
    echo "Artifacts dir: ${ARTIFACT_DIR}"

    test_cluster_health      || true
    test_opp_operators       || true
    test_acm_connectivity    || true
    test_acs_sensors         || true
    test_quay_pull           || true

    write_junit

    # Determine overall result
    local any_fail=0
    for r in "${TC_RESULTS[@]}"; do
        if [[ "$r" == "fail" ]]; then
            any_fail=1
            break
        fi
    done

    if (( any_fail )); then
        echo -e "\nOPP Smoke Tests: SOME TESTS FAILED"
        exit 1
    fi

    echo -e "\nOPP Smoke Tests: ALL PASSED"
    exit 0
}

main "$@"
