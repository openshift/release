#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# OPP post-upgrade smoke tests
#
# Validates that OPP bundle components (ACM, ACS, ODF, Quay) are healthy
# after an OCP upgrade.  Produces JUnit XML consumed by Prow / Sippy /
# TestGrid.
# ---------------------------------------------------------------------------

# NOTE: OPP_OPERATORS and SMOKE_SETTLE_SECONDS may be set via workflow env (naming deviates from OPP__ convention)
OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"
SMOKE_SETTLE_SECONDS="${SMOKE_SETTLE_SECONDS:-120}"

typeset junitFile="${ARTIFACT_DIR}/junit_opp_smoke.xml"

# Accumulators for JUnit generation
typeset -a tcNamesArr=()
typeset -a tcResultsArr=()    # "pass" or "fail"
typeset -a tcMessagesArr=()   # failure message (empty when pass)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

AddResult() {
    typeset name="${1:-}"; (($#)) && shift
    typeset result="${1:-}"; (($#)) && shift
    typeset message="${1:-}"; (($#)) && shift
    tcNamesArr+=("${name}")
    tcResultsArr+=("${result}")
    tcMessagesArr+=("${message}")
    true
}

XmlEscape() {
    typeset text="${1:-}"; (($#)) && shift
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&apos;}"
    printf '%s' "${text}"
}

WriteJunit() {
    typeset -i total=${#tcNamesArr[@]}
    typeset -i failCount=0
    for r in "${tcResultsArr[@]}"; do
        if [[ "${r}" == "fail" ]]; then
            (( failCount++ )) || true
        fi
    done

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"opp-smoke\" tests=\"${total}\" failures=\"${failCount}\">"
        for i in "${!tcNamesArr[@]}"; do
            typeset name=""
            name="$(XmlEscape "${tcNamesArr[$i]}")"
            echo "  <testcase classname=\"opp-smoke\" name=\"${name}\">"
            if [[ "${tcResultsArr[$i]}" == "fail" ]]; then
                typeset msg=""
                msg="$(XmlEscape "${tcMessagesArr[$i]}")"
                echo "    <failure message=\"${msg}\"></failure>"
            fi
            echo "  </testcase>"
        done
        echo "</testsuite>"
    } > "${junitFile}"
    : "JUnit XML written to ${junitFile}"
}

# shellcheck disable=SC2317  # invoked via trap
CollectExitArtifacts() {
    : "Collecting exit diagnostics..."
    oc get clusteroperators -o yaml > "${ARTIFACT_DIR}/clusteroperators.yaml" || true
    oc get csv --all-namespaces -o yaml > "${ARTIFACT_DIR}/csvs.yaml" || true
    oc get nodes -o yaml > "${ARTIFACT_DIR}/nodes.yaml" || true
}

trap CollectExitArtifacts EXIT

# ---------------------------------------------------------------------------
# Test 1: cluster-health
# ---------------------------------------------------------------------------

TestClusterHealth() {
    : "=== Test: cluster-health ==="
    typeset failMsg=""

    # ClusterOperators: Available=True, Degraded!=True
    typeset coProblems=""
    coProblems="$(oc get clusteroperators -o json | jq -r '
        .items[]
        | select(
            (.status.conditions // [] | map(select(.type=="Available")) | first | .status) != "True"
            or
            (.status.conditions // [] | map(select(.type=="Degraded")) | first | .status) == "True"
        )
        | .metadata.name
    ')" || true

    if [[ -n "${coProblems}" ]]; then
        failMsg="Unhealthy ClusterOperators: ${coProblems//$'\n'/, }"
        : "FAIL: ${failMsg}"
    else
        : "PASS: All ClusterOperators healthy"
    fi

    # Nodes: all Ready
    typeset nodeProblems=""
    nodeProblems="$(oc get nodes -o json | jq -r '
        .items[]
        | select(
            (.status.conditions // [] | map(select(.type=="Ready")) | first | .status) != "True"
        )
        | .metadata.name
    ')" || true

    if [[ -n "${nodeProblems}" ]]; then
        typeset nodeMsg="Not-Ready nodes: ${nodeProblems//$'\n'/, }"
        if [[ -n "${failMsg}" ]]; then
            failMsg="${failMsg}; ${nodeMsg}"
        else
            failMsg="${nodeMsg}"
        fi
        : "FAIL: ${nodeMsg}"
    else
        : "PASS: All nodes Ready"
    fi

    # ClusterVersion: Available=True
    typeset cvAvailable=""
    cvAvailable="$(oc get clusterversion version -o json | jq -r '
        .status.conditions // [] | map(select(.type=="Available")) | first | .status
    ')" || true

    if [[ "${cvAvailable}" != "True" ]]; then
        typeset cvMsg="ClusterVersion Available=${cvAvailable:-unknown}"
        if [[ -n "${failMsg}" ]]; then
            failMsg="${failMsg}; ${cvMsg}"
        else
            failMsg="${cvMsg}"
        fi
        : "FAIL: ${cvMsg}"
    else
        : "PASS: ClusterVersion Available=True"
    fi

    if [[ -z "${failMsg}" ]]; then
        AddResult "cluster-health" "pass"
    else
        AddResult "cluster-health" "fail" "${failMsg}"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: opp-operators
# ---------------------------------------------------------------------------

TestOppOperators() {
    : "=== Test: opp-operators ==="
    typeset failMsg=""

    typeset -a operatorsArr=()
    IFS=',' read -ra operatorsArr <<< "${OPP_OPERATORS}"
    for op in "${operatorsArr[@]}"; do
        op="$(echo "${op}" | xargs)"  # trim whitespace
        : "Checking operator: ${op}"

        # Find CSV matching this operator prefix
        typeset csvInfo=""
        csvInfo="$(oc get csv --all-namespaces -o json | jq -r --arg prefix "${op}" '
            .items[]
            | select(.metadata.name | startswith($prefix))
            | "\(.metadata.namespace)/\(.metadata.name)/\(.status.phase)"
        ' | head -1)" || true

        if [[ -z "${csvInfo}" ]]; then
            typeset notFoundMsg="CSV not found for ${op}"
            : "FAIL: ${notFoundMsg}"
            if [[ -n "${failMsg}" ]]; then
                failMsg="${failMsg}; ${notFoundMsg}"
            else
                failMsg="${notFoundMsg}"
            fi
            continue
        fi

        typeset csvNs="" csvName="" csvPhase=""
        csvNs="$(echo "${csvInfo}" | cut -d/ -f1)"
        csvName="$(echo "${csvInfo}" | cut -d/ -f2)"
        csvPhase="$(echo "${csvInfo}" | cut -d/ -f3)"

        if [[ "${csvPhase}" != "Succeeded" ]]; then
            typeset phaseMsg="CSV ${csvName} in phase ${csvPhase} (expected Succeeded)"
            : "FAIL: ${phaseMsg}"
            if [[ -n "${failMsg}" ]]; then
                failMsg="${failMsg}; ${phaseMsg}"
            else
                failMsg="${phaseMsg}"
            fi
        else
            : "PASS: CSV ${csvName} phase=Succeeded"
        fi

        # Check pods are Ready in the operator namespace (with settling window)
        : "Waiting ${SMOKE_SETTLE_SECONDS}s settling window for pods in ${csvNs}..."
        sleep "${SMOKE_SETTLE_SECONDS}"

        typeset notReadyPods=""
        notReadyPods="$(oc get pods -n "${csvNs}" -o json | jq -r '
            .items[]
            | select(.status.phase != "Succeeded")
            | select(
                (.status.containerStatuses // [] | map(select(.ready != true)) | length) > 0
            )
            | .metadata.name
        ')" || true

        if [[ -n "${notReadyPods}" ]]; then
            typeset podMsg="Not-ready pods in ${csvNs}: ${notReadyPods//$'\n'/, }"
            : "FAIL: ${podMsg}"
            if [[ -n "${failMsg}" ]]; then
                failMsg="${failMsg}; ${podMsg}"
            else
                failMsg="${podMsg}"
            fi
        else
            : "PASS: All pods ready in ${csvNs}"
        fi
    done

    if [[ -z "${failMsg}" ]]; then
        AddResult "opp-operators" "pass"
    else
        AddResult "opp-operators" "fail" "${failMsg}"
    fi
}

# ---------------------------------------------------------------------------
# Test 3: acm-connectivity
# ---------------------------------------------------------------------------

TestAcmConnectivity() {
    : "=== Test: acm-connectivity ==="
    typeset failMsg=""

    # Check if ManagedCluster resources exist
    typeset -i mcCount=0
    mcCount=$(oc get managedclusters -o json | jq '.items | length') || true

    if [[ "${mcCount}" -eq 0 ]]; then
        : "SKIP: No ManagedCluster resources found"
        AddResult "acm-connectivity" "pass" ""
        return
    fi

    typeset mcProblems=""
    mcProblems="$(oc get managedclusters -o json | jq -r '
        .items[]
        | select(
            (.status.conditions // [] | map(select(.type=="ManagedClusterConditionAvailable")) | first | .status) != "True"
        )
        | .metadata.name
    ')" || true

    if [[ -n "${mcProblems}" ]]; then
        failMsg="ManagedClusters not available: ${mcProblems//$'\n'/, }"
        : "FAIL: ${failMsg}"
    else
        : "PASS: All ManagedClusters available"
    fi

    if [[ -z "${failMsg}" ]]; then
        AddResult "acm-connectivity" "pass"
    else
        AddResult "acm-connectivity" "fail" "${failMsg}"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: acs-sensors
# ---------------------------------------------------------------------------

TestAcsSensors() {
    : "=== Test: acs-sensors ==="
    typeset failMsg=""

    # Check SecuredCluster CR status first
    typeset scStatus=""
    scStatus="$(oc get securedclusters.platform.stackrox.io --all-namespaces -o json | jq -r '
        .items[]
        | "\(.metadata.namespace)/\(.metadata.name)/\(.status.conditions // [] | map(select(.type=="Deployed" or .type=="Initialized")) | map(.status) | join(","))"
    ' | head -1)" || true

    if [[ -n "${scStatus}" ]]; then
        typeset scNs="" scName="" scConds=""
        scNs="$(echo "${scStatus}" | cut -d/ -f1)"
        scName="$(echo "${scStatus}" | cut -d/ -f2)"
        scConds="$(echo "${scStatus}" | cut -d/ -f3)"
        : "SecuredCluster ${scName} in ${scNs}: conditions=${scConds}"

        # Verify sensor pods are Running in the SecuredCluster namespace
        typeset sensorStatus=""
        sensorStatus="$(oc get pods -n "${scNs}" -l app=sensor -o json | jq -r '
            .items[] | "\(.metadata.name):\(.status.phase)"
        ')" || true

        if [[ -z "${sensorStatus}" ]]; then
            failMsg="No sensor pods found in ${scNs}"
            : "FAIL: ${failMsg}"
        else
            typeset badSensors=""
            badSensors="$(echo "${sensorStatus}" | grep -v ':Running$' || true)"
            if [[ -n "${badSensors}" ]]; then
                failMsg="Sensor pods not running: ${badSensors//$'\n'/, }"
                : "FAIL: ${failMsg}"
            else
                : "PASS: Sensor pods running in ${scNs}"
            fi
        fi
    else
        # No SecuredCluster CR; check if ACS operator is even installed
        typeset acsCsv=""
        acsCsv="$(oc get csv --all-namespaces -o json | jq -r '
            .items[] | select(.metadata.name | startswith("rhacs-operator")) | .metadata.name
        ' | head -1)" || true

        if [[ -z "${acsCsv}" ]]; then
            : "SKIP: ACS operator not installed"
            AddResult "acs-sensors" "pass" ""
            return
        fi

        # ACS operator installed but no SecuredCluster CR
        : "SKIP: ACS operator installed but no SecuredCluster CR found"
        AddResult "acs-sensors" "pass" ""
        return
    fi

    if [[ -z "${failMsg}" ]]; then
        AddResult "acs-sensors" "pass"
    else
        AddResult "acs-sensors" "fail" "${failMsg}"
    fi
}

# ---------------------------------------------------------------------------
# Test 5: quay-pull
# ---------------------------------------------------------------------------

TestQuayPull() {
    : "=== Test: quay-pull ==="
    typeset failMsg=""

    # Find the Quay registry route
    typeset quayRoute=""
    quayRoute="$(oc get routes --all-namespaces -o json | jq -r '
        .items[]
        | select(.metadata.name | test("quay"; "i"))
        | select(.spec.host | test("quay"; "i"))
        | .spec.host
    ' | head -1)" || true

    if [[ -z "${quayRoute}" ]]; then
        # Try looking for QuayRegistry CR to find the route
        quayRoute="$(oc get quayregistries.quay.redhat.com --all-namespaces -o json | jq -r '
            .items[0].status.registryEndpoint // empty
        ' | sed 's|^https://||')" || true
    fi

    if [[ -z "${quayRoute}" ]]; then
        # Check if Quay operator is even installed
        typeset quayCsv=""
        quayCsv="$(oc get csv --all-namespaces -o json | jq -r '
            .items[] | select(.metadata.name | startswith("quay-operator")) | .metadata.name
        ' | head -1)" || true

        if [[ -z "${quayCsv}" ]]; then
            : "SKIP: Quay operator not installed"
            AddResult "quay-pull" "pass" ""
            return
        fi

        failMsg="Quay operator installed but no registry route found"
        : "FAIL: ${failMsg}"
        AddResult "quay-pull" "fail" "${failMsg}"
        return
    fi

    : "Found Quay route: ${quayRoute}"

    # Attempt to pull the Quay health endpoint (API check instead of image pull
    # since we may not have registry credentials configured)
    typeset httpCode=""
    httpCode="$(curl -sk -o /dev/null -w '%{http_code}' "https://${quayRoute}/api/v1/discovery" --max-time 30)" || true

    if [[ "${httpCode}" =~ ^(200|401|403)$ ]]; then
        : "PASS: Quay registry responding (HTTP ${httpCode}) at ${quayRoute}"
    else
        failMsg="Quay registry unreachable at ${quayRoute} (HTTP ${httpCode:-timeout})"
        : "FAIL: ${failMsg}"
    fi

    if [[ -z "${failMsg}" ]]; then
        AddResult "quay-pull" "pass"
    else
        AddResult "quay-pull" "fail" "${failMsg}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Main() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    : "OPP Smoke Tests starting"
    : "Operators: ${OPP_OPERATORS}"
    : "Settle window: ${SMOKE_SETTLE_SECONDS}s"
    : "Artifacts dir: ${ARTIFACT_DIR}"

    TestClusterHealth      || true
    TestOppOperators       || true
    TestAcmConnectivity    || true
    TestAcsSensors         || true
    TestQuayPull           || true

    WriteJunit

    # Determine overall result
    typeset -i hasAnyFail=0
    for r in "${tcResultsArr[@]}"; do
        if [[ "${r}" == "fail" ]]; then
            hasAnyFail=1
            break
        fi
    done

    if (( hasAnyFail )); then
        : "OPP Smoke Tests: SOME TESTS FAILED"
        exit 1
    fi

    : "OPP Smoke Tests: ALL PASSED"
    exit 0
}

Main "$@"
