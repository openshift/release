#!/bin/bash
#
# Automated Submariner diagnostics using subctl.
# Ref: https://submariner.io/operations/troubleshooting/#automated-troubleshooting
#
# Runs subctl show all, diagnose all, and diagnose firewall inter-cluster
# against every spoke cluster.  Always exits 0 — diagnostic only, never fails the job.
# Individual command failures are guarded with || true so the step continues even if
# one diagnostic command fails; set -e and set -x are still required by MPEX BP.
set -euxo pipefail; shopt -s inherit_errexit

typeset -r subctlBin="/tmp/bin/subctl"
# ARTIFACT_DIR may be unset early in the script; use :- to avoid set -u abort.
# The precondition check below validates it is non-empty before any writes.
typeset -r diagDir="${ARTIFACT_DIR:-}/submariner-diag"
[[ "${ACM_SPOKE_CLUSTER_COUNT}" =~ ^[1-9][0-9]*$ ]] \
    || { : "ACM_SPOKE_CLUSTER_COUNT must be a positive decimal integer (got: '${ACM_SPOKE_CLUSTER_COUNT}')"; false; }
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"

typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()

# InstallSubctl — install subctl to /tmp/bin/ at step runtime.
# Downloads from GitHub releases using SUBMARINER_SUBCTL_VERSION (matches the
# env var name used by submariner-cloud-prepare, broker-join, and verify steps).
# Requires xz (pre-installed in the cli-with-git step image).
# Returns 1 (non-fatal) if any step fails; callers check exit status.
#
# WHY not SHARED_DIR: large binaries cause CI operator "Request entity too large"
# when serialising SHARED_DIR into a Kubernetes Secret between steps (3 MB limit).
function InstallSubctl () {
    mkdir -p /tmp/bin || return 1
    [[ -x "${subctlBin}" ]] && return 0

    typeset version="${SUBMARINER_SUBCTL_VERSION:?SUBMARINER_SUBCTL_VERSION must be set}"

    # Trusted SHA-256 digests for immutable versioned subctl linux/amd64 archives.
    # Only vX.Y.Z releases are immutable; release-X.Y rolling branch tags are
    # rebuilt on every branch push — SHA pinning is not meaningful for those.
    # To add a versioned release: compute sha256sum of the .tar.xz and add an entry.
    typeset -A _subctlDigests=(
        # [v0.24.0]="<sha256>"
    )

    typeset tarUrl="https://github.com/submariner-io/subctl/releases/download/subctl-${version}/subctl-${version}-linux-amd64.tar.xz"
    typeset tmpTar; tmpTar="$(mktemp /tmp/subctl-XXXXXX.tar.xz)" || return 1
    typeset tmpDir; tmpDir="$(mktemp -d /tmp/subctl-dir-XXXXXX)" || return 1

    curl -fsSL "${tarUrl}" -o "${tmpTar}"           || { rm -rf "${tmpTar}" "${tmpDir}"; return 1; }

    # Versioned releases (vX.Y.Z) must have a trusted digest; rolling branch
    # tags (release-X.Y) skip digest verification by design.
    if [[ "${version}" == release-* ]]; then
        : "Rolling branch tag ${version}: skipping SHA-256 verification"
    elif [[ "${version}" == v* ]]; then
        typeset expectedSha="${_subctlDigests[${version}]:-}"
        if [[ -z "${expectedSha}" ]]; then
            printf 'ERROR: No trusted SHA-256 digest for subctl %s — add it to _subctlDigests\n' "${version}" >&2
            rm -rf "${tmpTar}" "${tmpDir}"; return 1
        fi
        typeset actualSha; actualSha="$(sha256sum "${tmpTar}" | awk '{print $1}')"
        if [[ "${actualSha}" != "${expectedSha}" ]]; then
            printf 'ERROR: subctl %s SHA-256 mismatch\n  expected: %s\n  actual:   %s\n' \
                "${version}" "${expectedSha}" "${actualSha}" >&2
            rm -rf "${tmpTar}" "${tmpDir}"; return 1
        fi
        : "SHA-256 verified for subctl ${version}"
    else
        printf 'ERROR: Unsupported SUBMARINER_SUBCTL_VERSION format: %s (use release-X.Y or vX.Y.Z)\n' \
            "${version}" >&2
        rm -rf "${tmpTar}" "${tmpDir}"; return 1
    fi

    tar -xJf "${tmpTar}" -C "${tmpDir}"             || { rm -rf "${tmpTar}" "${tmpDir}"; return 1; }
    typeset extracted; extracted="$(find "${tmpDir}" -maxdepth 2 -name 'subctl' -type f | head -1)"
    [[ -n "${extracted}" ]]                         || { rm -rf "${tmpTar}" "${tmpDir}"; return 1; }
    cp "${extracted}" "${subctlBin}"                || { rm -rf "${tmpTar}" "${tmpDir}"; return 1; }
    chmod +x "${subctlBin}"
    rm -rf "${tmpTar}" "${tmpDir}"
    true
}

# LoadSpokeConfig — populate spoke kubeconfig and name arrays from SHARED_DIR.
# Returns 1 (non-fatal) if any expected file is missing.
function LoadSpokeConfig () {
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
function ShowAll () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    typeset outFile="${diagDir}/show-all-${name}.txt"

    KUBECONFIG="${kc}" "${subctlBin}" show all > "${outFile}" 2>&1 || true
    true
}

# DiagnoseAll — subctl diagnose all: health check across all submariner components.
function DiagnoseAll () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    typeset outFile="${diagDir}/diagnose-all-${name}.txt"

    KUBECONFIG="${kc}" "${subctlBin}" diagnose all > "${outFile}" 2>&1 || true
    true
}

# BuildMergedKubeconfig — merge two spoke kubeconfigs with unique named contexts
# into a temp file for subctl commands requiring --context / --remotecontext.
# Returns the merged kubeconfig path via stdout; cleans up and returns 1 on any
# failure so callers can guard with ||.
function BuildMergedKubeconfig () {
    typeset kc1="${1:?}"; (($#)) && shift
    typeset kc2="${1:?}"; (($#)) && shift
    typeset name1="${1:?}"; (($#)) && shift
    typeset name2="${1:?}"; (($#)) && shift

    typeset kc1Renamed kc2Renamed mergedKc
    kc1Renamed="$(mktemp /tmp/kc1-diag-XXXXXX.json)"    || return 1
    kc2Renamed="$(mktemp /tmp/kc2-diag-XXXXXX.json)"    || { rm -f "${kc1Renamed}"; return 1; }
    mergedKc="$(mktemp /tmp/kc-merged-diag-XXXXXX.json)" || { rm -f "${kc1Renamed}" "${kc2Renamed}"; return 1; }

    if ! KUBECONFIG="${kc1}" oc config view -o json --raw | \
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
        ' > "${kc1Renamed}"; then
        rm -f "${kc1Renamed}" "${kc2Renamed}" "${mergedKc}"
        return 1
    fi

    if ! KUBECONFIG="${kc2}" oc config view -o json --raw | \
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
        ' > "${kc2Renamed}"; then
        rm -f "${kc1Renamed}" "${kc2Renamed}" "${mergedKc}"
        return 1
    fi

    if ! KUBECONFIG="${kc1Renamed}:${kc2Renamed}" oc config view --flatten -o json > "${mergedKc}"; then
        rm -f "${kc1Renamed}" "${kc2Renamed}" "${mergedKc}"
        return 1
    fi
    rm -f "${kc1Renamed}" "${kc2Renamed}"

    printf '%s' "${mergedKc}"
}

# DiagnoseFirewallInterCluster — subctl diagnose firewall inter-cluster between a pair.
# Always returns 0 — diagnostic step must never fail the CI job.
function DiagnoseFirewallInterCluster () {
    typeset kc1="${1:?}"; (($#)) && shift
    typeset kc2="${1:?}"; (($#)) && shift
    typeset name1="${1:?}"; (($#)) && shift
    typeset name2="${1:?}"; (($#)) && shift

    typeset outFile="${diagDir}/diagnose-firewall-${name1}-to-${name2}.txt"
    typeset mergedKc
    mergedKc="$(BuildMergedKubeconfig "${kc1}" "${kc2}" "${name1}" "${name2}")" \
        || { printf 'WARNING: BuildMergedKubeconfig failed for %s<->%s — skipping firewall diag\n' \
                "${name1}" "${name2}" >&2; return 0; }

    KUBECONFIG="${mergedKc}" "${subctlBin}" diagnose firewall inter-cluster \
        --context   "${name1}-admin" \
        --remotecontext "${name2}-admin" \
        > "${outFile}" 2>&1 || true

    rm -f "${mergedKc}"
    true
}

# GatherDiags — subctl gather: collect deep diagnostic bundle for a single spoke.
# Archives the bundle under ${ARTIFACT_DIR}/submariner-diag/gather/<name>/.
# subctl gather uses KUBECONFIG env var and writes to --dir; failures are
# non-fatal (|| true) so one broken spoke does not suppress the rest.
function GatherDiags () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    typeset gatherDir="${diagDir}/gather/${name}"

    mkdir -p "${gatherDir}"
    KUBECONFIG="${kc}" "${subctlBin}" gather \
        --dir "${gatherDir}" \
        > "${diagDir}/gather-${name}.txt" 2>&1 || true
    true
}

# --- Main ---

# Precondition checks — warn and skip rather than abort (diagnostic-only step).
typeset _diagSkip=false

for _cmd in oc curl jq; do
    command -v "${_cmd}" 1>/dev/null \
        || { printf 'WARNING: %s not found — skipping diagnostics\n' "${_cmd}" >&2; _diagSkip=true; }
done

if [[ -z "${SHARED_DIR:-}" || -z "${ARTIFACT_DIR:-}" ]]; then
    printf 'WARNING: SHARED_DIR or ARTIFACT_DIR unset — skipping diagnostics\n' >&2
    _diagSkip=true
fi

mkdir -p "${diagDir}" || { printf 'WARNING: mkdir -p %s failed — skipping diagnostics\n' "${diagDir}" >&2; _diagSkip=true; }

if [[ "${_diagSkip}" != "true" ]]; then
    LoadSpokeConfig \
        || { printf 'WARNING: LoadSpokeConfig failed — skipping diagnostics\n' >&2; _diagSkip=true; }
fi

if [[ "${_diagSkip}" != "true" ]]; then
    InstallSubctl \
        || { printf 'WARNING: InstallSubctl failed — skipping diagnostics\n' >&2; _diagSkip=true; }
fi

if [[ "${_diagSkip}" == "true" ]]; then
    printf 'INFO: Submariner diagnostics skipped due to setup failure — see warnings above\n' >&2
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
    GatherDiags "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
done

: "Submariner diagnostics complete — artifacts in ${diagDir}"
true
