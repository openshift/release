#!/bin/bash
#
# Automated Submariner diagnostics using subctl.
# Ref: https://submariner.io/operations/troubleshooting/#automated-troubleshooting
#
# Runs subctl show all, diagnose all, diagnose firewall inter-cluster, and gather
# against every spoke cluster.  Always exits 0 — diagnostic only, never fails the job.
#
# Use -uo (no -e, no -x) so that individual command failures never abort the script.
# Each function guards its own failures with || true.
set -uo pipefail

typeset -r subctlBin="/tmp/bin/subctl"
typeset -r diagDir="${ARTIFACT_DIR}/submariner-diag"
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"

typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()

# InstallSubctl — install subctl to /tmp/bin/ at step runtime.
# WHY not SHARED_DIR: large binaries cause CI operator "Request entity too large"
# when serialising SHARED_DIR into a Kubernetes Secret between steps (3 MB limit).
# Returns 1 (non-fatal) if installation fails; callers check exit status.
InstallSubctl() {
    mkdir -p /tmp/bin || return 1
    if [[ -x "${subctlBin}" ]]; then
        return 0
    fi
    curl -Ls https://get.submariner.io | bash || return 1
    cp "${HOME}/.local/bin/subctl" "${subctlBin}" || return 1
    chmod +x "${subctlBin}" || return 1
    true
}

# LoadSpokeConfig — populate spoke kubeconfig and name arrays from SHARED_DIR.
# Returns 1 (non-fatal) if any expected file is missing.
LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        if [[ ! -f "${kcFile}" || ! -f "${nameFile}" ]]; then
            : "LoadSpokeConfig: missing files for spoke ${i} — skipping"
            return 1
        fi

        spokeKubeconfigsArr+=("${kcFile}")
        spokeNamesArr+=("$(< "${nameFile}")")
    done
    true
}

# ShowAll — subctl show all: endpoints, gateways, networks, connections overview.
ShowAll() {
    typeset kc="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    typeset outFile="${diagDir}/show-all-${name}.txt"

    KUBECONFIG="${kc}" "${subctlBin}" show all > "${outFile}" 2>&1 || true
    true
}

# DiagnoseAll — subctl diagnose all: health check across all submariner components.
DiagnoseAll() {
    typeset kc="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    typeset outFile="${diagDir}/diagnose-all-${name}.txt"

    KUBECONFIG="${kc}" "${subctlBin}" diagnose all > "${outFile}" 2>&1 || true
    true
}

# BuildMergedKubeconfig — merge two spoke kubeconfigs with unique named contexts
# into a temp file for subctl commands requiring --context / --remotecontext.
# Returns the merged kubeconfig path via stdout.
BuildMergedKubeconfig() {
    typeset kc1="${1:?}"; (($#)) && shift
    typeset kc2="${1:?}"; (($#)) && shift
    typeset name1="${1:?}"; (($#)) && shift
    typeset name2="${1:?}"; (($#)) && shift

    typeset kc1Renamed kc2Renamed mergedKc
    kc1Renamed="$(mktemp /tmp/kc1-diag-XXXXXX.json)"
    kc2Renamed="$(mktemp /tmp/kc2-diag-XXXXXX.json)"
    mergedKc="$(mktemp /tmp/kc-merged-diag-XXXXXX.json)"

    KUBECONFIG="${kc1}" oc config view -o json --raw | \
        jq \
            --arg ctx "${name1}-admin" \
            --arg cls "${name1}-cluster" \
            --arg usr "${name1}-user" \
        '
            .contexts[0].name                  = $ctx |
            .contexts[0].context.cluster       = $cls |
            .contexts[0].context.user          = $usr |
            .clusters[0].name                  = $cls |
            .users[0].name                     = $usr |
            ."current-context"                 = $ctx
        ' > "${kc1Renamed}"

    KUBECONFIG="${kc2}" oc config view -o json --raw | \
        jq \
            --arg ctx "${name2}-admin" \
            --arg cls "${name2}-cluster" \
            --arg usr "${name2}-user" \
        '
            .contexts[0].name                  = $ctx |
            .contexts[0].context.cluster       = $cls |
            .contexts[0].context.user          = $usr |
            .clusters[0].name                  = $cls |
            .users[0].name                     = $usr |
            ."current-context"                 = $ctx
        ' > "${kc2Renamed}"

    KUBECONFIG="${kc1Renamed}:${kc2Renamed}" oc config view --flatten -o json > "${mergedKc}"
    rm -f "${kc1Renamed}" "${kc2Renamed}"

    printf '%s' "${mergedKc}"
}

# DiagnoseFirewallInterCluster — subctl diagnose firewall inter-cluster between a pair.
DiagnoseFirewallInterCluster() {
    typeset kc1="${1:?}"; (($#)) && shift
    typeset kc2="${1:?}"; (($#)) && shift
    typeset name1="${1:?}"; (($#)) && shift
    typeset name2="${1:?}"; (($#)) && shift

    typeset outFile="${diagDir}/diagnose-firewall-${name1}-to-${name2}.txt"
    typeset mergedKc
    mergedKc="$(BuildMergedKubeconfig "${kc1}" "${kc2}" "${name1}" "${name2}")"

    KUBECONFIG="${mergedKc}" "${subctlBin}" diagnose firewall inter-cluster \
        --context   "${name1}-admin" \
        --remotecontext "${name2}-admin" \
        > "${outFile}" 2>&1 || true

    rm -f "${mergedKc}"
    true
}

# GatherSubmariner — subctl gather for deep diagnostics; archives tarball to diagDir.
GatherSubmariner() {
    typeset kc="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift

    typeset gatherWorkDir
    gatherWorkDir="$(mktemp -d /tmp/subctl-gather-XXXXXX)"

    (
        cd "${gatherWorkDir}"
        KUBECONFIG="${kc}" "${subctlBin}" gather > "${diagDir}/gather-${name}.log" 2>&1 || true

        # Archive whatever subctl gather produced
        typeset tarball=""
        typeset gatherDir=""
        for d in submariner-*/; do
            [[ -d "${d}" ]] && gatherDir="${d}" && break
        done

        if [[ -n "${gatherDir}" ]]; then
            tar czf "${diagDir}/gather-${name}.tar.gz" "${gatherDir}"
            rm -rf "${gatherDir}"
        fi
    )
    rm -rf "${gatherWorkDir}"
    true
}

# --- Main ---

# Precondition checks — warn and skip rather than abort (diagnostic-only step).
typeset _diagSkip=false

for _cmd in oc curl jq; do
    command -v "${_cmd}" 1>/dev/null || { : "WARNING: ${_cmd} not found — skipping diagnostics"; _diagSkip=true; }
done

if [[ -z "${SHARED_DIR:-}" || -z "${ARTIFACT_DIR:-}" ]]; then
    : "WARNING: SHARED_DIR or ARTIFACT_DIR unset — skipping diagnostics"
    _diagSkip=true
fi

mkdir -p "${diagDir}/gather" || _diagSkip=true

if [[ "${_diagSkip}" != "true" ]]; then
    LoadSpokeConfig || { : "WARNING: LoadSpokeConfig failed — skipping diagnostics"; _diagSkip=true; }
fi

if [[ "${_diagSkip}" != "true" ]]; then
    InstallSubctl || { : "WARNING: InstallSubctl failed — skipping diagnostics"; _diagSkip=true; }
fi

if [[ "${_diagSkip}" == "true" ]]; then
    : "Submariner diagnostics skipped due to setup failure — see warnings above"
    exit 0
fi

: "=== subctl show all (per spoke) ==="
typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    ShowAll "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
done

: "=== subctl diagnose all (per spoke) ==="
for ((i = 0; i < spokeCount; i++)); do
    DiagnoseAll "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
done

: "=== subctl diagnose firewall inter-cluster (per spoke pair) ==="
typeset -i j
for ((i = 0; i < spokeCount; i++)); do
    for ((j = i + 1; j < spokeCount; j++)); do
        DiagnoseFirewallInterCluster \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeKubeconfigsArr[j]}" \
            "${spokeNamesArr[i]}" \
            "${spokeNamesArr[j]}"
        DiagnoseFirewallInterCluster \
            "${spokeKubeconfigsArr[j]}" \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[j]}" \
            "${spokeNamesArr[i]}"
    done
done

: "=== subctl gather (per spoke) ==="
for ((i = 0; i < spokeCount; i++)); do
    GatherSubmariner "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
done

: "Submariner diagnostics complete — artifacts in ${diagDir}"
true
