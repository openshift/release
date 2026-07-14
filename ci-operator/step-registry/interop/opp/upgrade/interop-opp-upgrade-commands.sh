#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# NOTE: UPGRADE_TIMEOUT, POLL_INTERVAL, STALL_WINDOW, OPP_OPERATORS are set via step config YAML
# (naming deviates from OPP__ convention)
UPGRADE_TIMEOUT="${UPGRADE_TIMEOUT:-130}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
STALL_WINDOW="${STALL_WINDOW:-10}"
OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"

typeset -i exitCode=0
typeset upgradeTarget=""
typeset targetVersion=""
typeset -i targetMinorVersion=0
typeset sourceVersion=""
typeset -i sourceMinorVersion=0
typeset forceUpdate="false"

DebugOnExit() {
    if (( exitCode != 0 )); then
        : "### DEBUG: Upgrade failure diagnostics ###"
        if [[ -n "${targetMinorVersion:-}" ]] && (( targetMinorVersion >= 16 )); then
            : "# oc adm upgrade status"
            env OC_ENABLE_CMD_UPGRADE_STATUS='true' oc adm upgrade status --details=all || true
        fi
        : "# ClusterVersion YAML"
        oc get clusterversion/version -oyaml || : "unavailable"
        : "# MachineConfigs"
        oc get machineconfig || : "unavailable"

        : "# Abnormal nodes"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read -r node; do
            : "### oc describe node ${node} ###"
            oc describe node "${node}" || true
        done

        : "# Abnormal ClusterOperators"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read -r co; do
            : "### oc describe co ${co} ###"
            oc describe co "${co}" || true
        done

        : "# Abnormal MachineConfigPools"
        oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read -r mcp; do
            : "### oc describe mcp ${mcp} ###"
            oc describe mcp "${mcp}" || true
        done

        : "# OPP Operator CSVs"
        oc get csv -A || : "unavailable"
    fi
}

trap 'exitCode=$?; DebugOnExit' EXIT TERM

KUBECONFIG="" oc --loglevel=8 registry login

ResolveTargetImage() {
    typeset image="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}"
    if [[ -z "${image}" ]]; then
        : "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is not set; cannot resolve upgrade target"
        exit 3
    fi
    : "Target image: ${image}"
    upgradeTarget="${image}"
}

CheckSigned() {
    typeset payload="${1}"
    typeset digest="" algorithm="" hashValue=""
    typeset -i response=0 try=0 maxRetries=3
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
    else
        digest="$(oc image info "${payload}" -o json | jq -r '.digest')"
    fi
    : "Image digest: ${digest}"
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hashValue="$(echo "${digest}" | cut -f2 -d:)"
    while (( try < maxRetries && response != 200 )); do
        : "Signature check attempt #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null \
            --write-out "%{http_code}" \
            "https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hashValue}/signature-1")
        (( try += 1 ))
        if (( response != 200 && try < maxRetries )); then
            sleep 60
        fi
    done
    if (( response == 200 )); then
        : "Image is signed"
        return 0
    else
        : "Image is not signed"
        return 1
    fi
}

AdminAck() {
    typeset -i srcMinor="${1}" tgtMinor="${2}"
    if (( srcMinor == tgtMinor )) || (( srcMinor < 8 )); then
        : "Admin ack not required (z-stream or pre-4.8)"
        return 0
    fi

    typeset gates=""
    gates="$(oc -n openshift-config-managed get configmap admin-gates -o json | jq -r '.data')" || true
    if [[ -z "${gates}" || "${gates}" == "null" ]]; then
        : "No admin gates found"
        return 0
    fi
    : "Admin gates: ${gates}"

    if [[ ${gates} != *"ack-4.${srcMinor}"* ]]; then
        : "No acks required for source minor version ${srcMinor}"
        return 0
    fi

    : "Patching admin acks for 4.${srcMinor} -> 4.${tgtMinor}"
    typeset ackKeys=""
    ackKeys="$(echo "${gates}" | jq -r 'keys[]')"
    typeset ack=""
    for ack in ${ackKeys}; do
        if [[ "${ack}" == *"ack-4.${srcMinor}"* ]]; then
            : "Applying ack: ${ack}"
            oc -n openshift-config patch configmap admin-acks \
                --patch '{"data":{"'"${ack}"'": "true"}}' --type=merge
        fi
    done

    : "Waiting for admin acks to take effect (up to 5 minutes)"
    typeset -i elapsed=0
    while (( elapsed < 5 )); do
        sleep 1m
        (( elapsed += 1 ))
        if ! oc adm upgrade 2>&1 | grep -q "AdminAckRequired"; then
            : "Admin acks applied successfully"
            return 0
        fi
        : "Still waiting... (${elapsed}/5 min)"
    done
    : "Timed out waiting for admin acks"
    return 1
}

UpdateCcoAnnotation() {
    typeset srcVersion="${1}" tgtVersion="${2}"
    typeset -i srcMinor=0 tgtMinor=0
    srcMinor="$(echo "${srcVersion}" | cut -f2 -d.)"
    tgtMinor="$(echo "${tgtVersion}" | cut -f2 -d.)"

    if (( srcMinor == tgtMinor )) || (( srcMinor < 8 )); then
        : "CCO annotation not required (z-stream or pre-4.8)"
        return 0
    fi

    typeset ccoMode=""
    ccoMode="$(oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}')" || true
    if [[ "${ccoMode}" != "Manual" ]]; then
        : "CCO annotation not required (mode: ${ccoMode:-default})"
        return 0
    fi

    typeset toVersion=""
    toVersion="$(echo "${tgtVersion}" | cut -f1 -d-)"
    : "Patching CCO upgradeable-to annotation: ${toVersion}"
    oc patch cloudcredential.operator.openshift.io/cluster \
        --patch '{"metadata":{"annotations": {"cloudcredential.openshift.io/upgradeable-to": "'"${toVersion}"'"}}}' \
        --type=merge

    : "Waiting for CCO annotation to take effect (up to 5 minutes)"
    typeset -i elapsed=0
    while (( elapsed < 5 )); do
        sleep 1m
        (( elapsed += 1 ))
        if ! oc adm upgrade 2>&1 | grep -q "MissingUpgradeableAnnotation"; then
            : "CCO annotation applied successfully"
            return 0
        fi
        : "Still waiting... (${elapsed}/5 min)"
    done
    : "Timed out waiting for CCO annotation"
    return 1
}

InitiateUpgrade() {
    typeset forceFlag="${1}"
    : "Initiating upgrade to ${upgradeTarget}"
    : "Force flag: ${forceFlag}"
    oc adm upgrade --to-image="${upgradeTarget}" --allow-explicit-upgrade --force="${forceFlag}"
    : "Upgrade command accepted at $(date '+%F %T')"

    sleep 10
    typeset progressing=""
    progressing="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" || true
    if [[ "${progressing}" != "True" ]]; then
        : "WARNING: CVO Progressing is not True after upgrade initiation (status: ${progressing})"
    else
        : "CVO confirmed Progressing=True"
    fi
}

MonitorUpgrade() {
    typeset -i pollCount=0
    typeset -i lastProgressChange=0
    lastProgressChange=$(date +%s)

    typeset statCmd="oc adm upgrade 2>&1 | grep -vE 'Upstream is unset|Upstream: https|available channels|No updates available|^$'"
    if (( targetMinorVersion >= 16 )); then
        statCmd="env OC_ENABLE_CMD_UPGRADE_STATUS=true oc adm upgrade status 2>&1 | grep -vE 'no token is currently in use|for additional description and links'"
    fi

    typeset prevStatus=""
    typeset snapshotDir="${ARTIFACT_DIR:-/tmp}/upgrade-progress"
    mkdir -p "${snapshotDir}"

    : "Monitoring upgrade (timeout: ${UPGRADE_TIMEOUT}m, poll: ${POLL_INTERVAL}s)"
    : "Upgrade monitoring start: $(date '+%F %T')"
    typeset -i startTime=0 deadline=0
    startTime=$(date +%s)
    deadline=$(( startTime + UPGRADE_TIMEOUT * 60 ))

    while (( $(date +%s) < deadline )); do
        sleep "${POLL_INTERVAL}"
        (( pollCount += 1 ))

        typeset currentStatus=""
        currentStatus="$(eval "${statCmd}")" || true
        if [[ -n "${currentStatus}" && "${currentStatus}" != "${prevStatus}" ]]; then
            : "=== Upgrade Status $(date '+%T') ==="
            echo "${currentStatus}"
            prevStatus="${currentStatus}"
            lastProgressChange=$(date +%s)
        fi

        if (( pollCount % 5 == 0 )); then
            oc get clusterversion version -o json > "${snapshotDir}/cv-$(date +%s).json" || true
        fi

        typeset cvOut="" avail="" progressing=""
        cvOut="$(oc get clusterversion --no-headers)" || continue
        avail="$(echo "${cvOut}" | awk '{print $3}')"
        progressing="$(echo "${cvOut}" | awk '{print $4}')"

        if [[ "${avail}" == "True" && "${progressing}" == "False" && "${cvOut}" == *"${targetVersion}"* ]]; then
            typeset -i endTime=0
            endTime=$(date +%s)
            : "Upgrade completed successfully at $(date '+%F %T')"
            : "Elapsed: $(( (endTime - startTime) / 60 ))m"
            return 0
        fi

        typeset -i now=0 stallSeconds=0
        now=$(date +%s)
        stallSeconds=$(( STALL_WINDOW * 60 ))
        if (( now - lastProgressChange > stallSeconds )); then
            : "WARNING: No upgrade progress change in ${STALL_WINDOW} minutes (possible stall)"
            oc get clusterversion version -o json > "${snapshotDir}/cv-stall-$(date +%s).json" || true
        fi
    done

    typeset -i endTime=0
    endTime=$(date +%s)
    : "Upgrade timed out after ${UPGRADE_TIMEOUT} minutes at $(date '+%F %T')"
    : "Elapsed: $(( (endTime - startTime) / 60 ))m"
    exit 2
}

StabilizeCluster() {
    : "Waiting for cluster stability (minimum-stable-period=5m, timeout=30m)"
    oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=30m
    : "Cluster is stable"
}

ValidatePlatformHealth() {
    : "Validating platform health"

    typeset avail="" progressing="" degraded=""
    avail="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
    progressing="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')"
    degraded="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')"
    if [[ "${avail}" != "True" || "${progressing}" != "False" || "${degraded}" != "False" ]]; then
        : "CVO health check failed: Available=${avail} Progressing=${progressing} Degraded=${degraded}"
        return 1
    fi
    : "CVO: Available=True, Progressing=False, Degraded=False"

    typeset unhealthyCo=""
    unhealthyCo="$(oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')"
    if [[ -n "${unhealthyCo}" ]]; then
        : "Unhealthy ClusterOperators: ${unhealthyCo}"
        return 1
    fi
    : "All ClusterOperators healthy"

    typeset unreadyNodes=""
    unreadyNodes="$(oc get node --no-headers | awk '$2 != "Ready" {print $1}')"
    if [[ -n "${unreadyNodes}" ]]; then
        : "Not-Ready nodes: ${unreadyNodes}"
        return 1
    fi
    : "All nodes Ready"

    typeset mcpIssues=""
    mcpIssues="$(oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')"
    if [[ -n "${mcpIssues}" ]]; then
        : "Unhealthy MachineConfigPools: ${mcpIssues}"
        return 1
    fi
    : "All MachineConfigPools updated"
    true
}

ValidateOppOperators() {
    : "Validating OPP operator health"
    typeset -a operators=()
    IFS=',' read -ra operators <<< "${OPP_OPERATORS}"

    : "Waiting 5 minutes for operator settling"
    sleep 300

    typeset allCsvs=""
    typeset -i failCount=0
    allCsvs="$(oc get csv -A --no-headers)" || {
        : "Failed to retrieve CSVs"
        return 1
    }

    typeset csvLine="" phase=""
    for op in "${operators[@]}"; do
        csvLine="$(echo "${allCsvs}" | grep "${op}" | head -1)" || true
        if [[ -z "${csvLine}" ]]; then
            : "CSV not found for operator: ${op}"
            (( failCount += 1 ))
            continue
        fi
        phase="$(echo "${csvLine}" | awk '{print $NF}')"
        if [[ "${phase}" != "Succeeded" ]]; then
            : "Operator ${op} CSV phase: ${phase} (expected: Succeeded)"
            (( failCount += 1 ))
        else
            : "Operator ${op}: CSV phase Succeeded"
        fi
    done

    if (( failCount > 0 )); then
        : "${failCount} OPP operator(s) not healthy after upgrade"
        : "Full CSV listing:"
        echo "${allCsvs}"
        return 1
    fi

    : "Checking pod readiness for OPP operator namespaces"
    typeset oppNamespaces=""
    oppNamespaces="$(echo "${allCsvs}" | grep -E "$(echo "${OPP_OPERATORS}" | tr ',' '|')" | awk '{print $1}' | sort -u)"
    typeset notReady="" ns=""
    for ns in ${oppNamespaces}; do
        notReady="$(oc get pods -n "${ns}" --no-headers | grep -v 'Completed' | grep -v 'Running' | grep -v 'Succeeded')" || true
        if [[ -n "${notReady}" ]]; then
            : "WARNING: Non-running pods in ${ns}:"
            echo "${notReady}"
        else
            : "All pods healthy in ${ns}"
        fi
    done

    : "All OPP operators validated successfully"
    true
}

Main() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    ResolveTargetImage

    targetVersion="$(oc adm release info "${upgradeTarget}" --output=json | jq -r '.metadata.version')"
    targetMinorVersion="$(echo "${targetVersion}" | cut -f2 -d.)"
    export targetVersion targetMinorVersion
    : "Target release: ${targetVersion} (minor: ${targetMinorVersion})"

    sourceVersion="$(oc get clusterversion --no-headers | awk '{print $2}')"
    sourceMinorVersion="$(echo "${sourceVersion}" | cut -f2 -d.)"
    export sourceVersion sourceMinorVersion
    : "Source release: ${sourceVersion} (minor: ${sourceMinorVersion})"

    forceUpdate="false"
    if ! CheckSigned "${upgradeTarget}"; then
        : "Target is unsigned; will use --force"
        forceUpdate="true"
    fi

    if [[ "${forceUpdate}" == "false" ]]; then
        AdminAck "${sourceMinorVersion}" "${targetMinorVersion}"
        UpdateCcoAnnotation "${sourceVersion}" "${targetVersion}"
    fi

    InitiateUpgrade "${forceUpdate}"
    MonitorUpgrade
    StabilizeCluster
    ValidatePlatformHealth
    ValidateOppOperators
    : "OCP upgrade and OPP validation completed successfully"
    true
}

Main "$@"
