#!/bin/bash
#
# Submariner Diagnostic Collection
#
# Runs after submariner-verify failures (post phase) to collect troubleshooting
# data. All commands run with '|| true' so this step never blocks job teardown.
#
# Per https://submariner.io/operations/troubleshooting/ the recommended approach:
#   1. subctl show all          — overview of gateways, connections, endpoints,
#                                  networks, versions on each cluster
#   2. subctl diagnose all      — automated health checks (firewall, kube-proxy,
#                                  MTU, pods, k8s-version, CNI) on each cluster
#   3. subctl diagnose firewall inter-cluster
#                               — bidirectional firewall probe between each pair
#   4. subctl gather            — collect full debug bundle → ARTIFACT_DIR
#
# SPOKE CLUSTERS: always runs for all spokes.
# HUB CLUSTER:   included when SUBMARINER_VERIFY_HUB_SPOKE=true.
#
# Output is written to ${ARTIFACT_DIR}/submariner-diagnose/ as text files
# and the subctl gather tarball, making them visible in Prow artifacts.
#
# This step always exits 0 — diagnostic failures must not block cluster teardown.
#

set -uo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

# ── Constants ─────────────────────────────────────────────────────────────────
typeset -r subctlBin="/tmp/bin/subctl"
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"
typeset verifyHubSpoke="${SUBMARINER_VERIFY_HUB_SPOKE}"

typeset -r diagDir="${ARTIFACT_DIR}/submariner-diagnose"

typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()

# ── InstallSubctl — install subctl to /tmp/bin/ ───────────────────────────────
InstallSubctl() {
    mkdir -p /tmp/bin
    if [[ -x "${subctlBin}" ]]; then
        return 0
    fi
    : "Installing subctl from get.submariner.io"
    curl -Ls https://get.submariner.io | bash
    cp "${HOME}/.local/bin/subctl" "${subctlBin}"
    chmod +x "${subctlBin}"
}

# ── LoadSpokeConfig — populate spoke arrays from SHARED_DIR ──────────────────
LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        if [[ ! -f "${kcFile}" || ! -f "${nameFile}" ]]; then
            : "WARNING: kubeconfig or name file missing for spoke ${i} — skipping"
            continue
        fi

        spokeKubeconfigsArr+=("${kcFile}")
        spokeNamesArr+=("$(< "${nameFile}")")
    done
}

# ── _IsolateAndRenameContext — create a clean single-context kubeconfig ────────
# Real OCP kubeconfigs all have context="admin", cluster="cluster", user="admin".
# Blindly indexing [0] breaks when there are extra entries or the merge would
# deduplicate identically-named clusters/users from different files.
#
# This function:
#   1. Reads the raw kubeconfig for the given cluster (--raw embeds cert data).
#   2. Follows .current-context → looks up the referenced cluster+user names.
#   3. Extracts ONLY those three entries (discards unrelated contexts/clusters/users).
#   4. Renames them to unique "$label-admin / $label-cluster / $label-user" names.
#
# Result is a self-contained single-context kubeconfig that is safe to merge.
_IsolateAndRenameContext() {
    typeset srcKubeconfig="${1:?}" label="${2:?}" outFile="${3:?}"

    KUBECONFIG="${srcKubeconfig}" oc config view --raw -o json | \
        jq --arg label "${label}" '
            (."current-context") as $origCtx |
            (  .contexts
             | map(select(.name == $origCtx))[0]
            ) as $ctxEntry |
            ($ctxEntry.context.cluster) as $origCluster |
            ($ctxEntry.context.user)    as $origUser    |
            {
              "apiVersion":      .apiVersion,
              "kind":            .kind,
              "preferences":     (.preferences // {}),
              "clusters": [
                .clusters[]
                | select(.name == $origCluster)
                | .name = ($label + "-cluster")
              ],
              "contexts": [{
                "name": ($label + "-admin"),
                "context": {
                  "cluster": ($label + "-cluster"),
                  "user":    ($label + "-user")
                }
              }],
              "users": [
                .users[]
                | select(.name == $origUser)
                | .name = ($label + "-user")
              ],
              "current-context": ($label + "-admin")
            }
        ' > "${outFile}"
}

# ── MergeKubeconfigs — build a multi-context kubeconfig for subctl gather ─────
# subctl gather and firewall inter-cluster need a merged kubeconfig with one
# uniquely named context per cluster.  We call _IsolateAndRenameContext for
# each cluster so no two files share a cluster/context/user name before we
# hand them to oc config view --flatten.
MergeKubeconfigs() {
    typeset outFile="${1:?}"; (($#)) && shift

    typeset -a kcFiles=()
    typeset -i i

    if [[ "${verifyHubSpoke}" == "true" ]]; then
        typeset hubTmp
        hubTmp="$(mktemp /tmp/kc-hub-XXXXXX.json)"
        _IsolateAndRenameContext "${KUBECONFIG}" "hub" "${hubTmp}"
        kcFiles+=("${hubTmp}")
    fi

    for ((i = 0; i < ${#spokeKubeconfigsArr[@]}; i++)); do
        typeset spokeTmp
        spokeTmp="$(mktemp /tmp/kc-spoke-${i}-XXXXXX.json)"
        _IsolateAndRenameContext "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" "${spokeTmp}"
        kcFiles+=("${spokeTmp}")
    done

    # All contexts/clusters/users now have unique names — safe to merge.
    # Use jq -s directly rather than 'oc config view --flatten': oc deduplicates
    # entries that share the same name, which would silently drop clusters if
    # renaming ever produced a collision.  jq -s concatenates faithfully.
    jq -s '
        {
          "apiVersion":      "v1",
          "kind":            "Config",
          "preferences":     {},
          "clusters":        [.[].clusters[]],
          "contexts":        [.[].contexts[]],
          "users":           [.[].users[]],
          "current-context": .[0]."current-context"
        }
    ' "${kcFiles[@]}" > "${outFile}"
    rm -f "${kcFiles[@]}"
}

# ── ShowAll — run subctl show all on one cluster ──────────────────────────────
ShowAll() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset outFile="${diagDir}/show-all-${clusterName}.txt"

    : "=== subctl show all on '${clusterName}' ==="
    {
        echo "=== subctl show all — ${clusterName} ==="
        echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo ""
        KUBECONFIG="${kubeconfig}" "${subctlBin}" show all 2>&1 || true
    } | tee "${outFile}" || true
}

# ── DiagnoseAll — run subctl diagnose all on one cluster ─────────────────────
DiagnoseAll() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset outFile="${diagDir}/diagnose-all-${clusterName}.txt"

    : "=== subctl diagnose all on '${clusterName}' ==="
    {
        echo "=== subctl diagnose all — ${clusterName} ==="
        echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo ""
        KUBECONFIG="${kubeconfig}" "${subctlBin}" diagnose all 2>&1 || true
    } | tee "${outFile}" || true
}

# ── DiagnoseFirewall — run subctl diagnose firewall inter-cluster ─────────────
# Requires a merged kubeconfig with both cluster contexts.
DiagnoseFirewall() {
    typeset mergedKc="${1:?}"; (($#)) && shift
    typeset ctx1="${1:?}"; (($#)) && shift
    typeset ctx2="${1:?}"; (($#)) && shift
    typeset pairName="${1:?}"; (($#)) && shift
    typeset outFile="${diagDir}/diagnose-firewall-${pairName}.txt"

    : "=== subctl diagnose firewall inter-cluster ${ctx1} ↔ ${ctx2} ==="
    {
        echo "=== subctl diagnose firewall inter-cluster — ${pairName} ==="
        echo "Contexts: ${ctx1} ↔ ${ctx2}"
        echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo ""
        KUBECONFIG="${mergedKc}" "${subctlBin}" diagnose firewall inter-cluster \
            --context "${ctx1}" \
            --remotecontext "${ctx2}" \
            2>&1 || true
    } | tee "${outFile}" || true
}

# ── GatherAll — run subctl gather with all cluster contexts ──────────────────
GatherAll() {
    typeset mergedKc="${1:?}"; (($#)) && shift

    typeset gatherDir="${diagDir}/gather"
    mkdir -p "${gatherDir}"

    : "=== subctl gather (all clusters) ==="
    (
        cd "${gatherDir}"
        KUBECONFIG="${mergedKc}" "${subctlBin}" gather 2>&1 || true
    ) || true

    # List collected files
    find "${gatherDir}" -type f | sort || true
}

# ── OcDumpGatewayStatus — dump gateway CRs as YAML for quick reference ────────
OcDumpGatewayStatus() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset outFile="${diagDir}/gateway-cr-${clusterName}.yaml"

    KUBECONFIG="${kubeconfig}" oc get gateways.submariner.io \
        -n submariner-operator \
        -o yaml > "${outFile}" 2>&1 || true
}

# ── OcDumpPodLogs — dump submariner component pod logs ───────────────────────
OcDumpPodLogs() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset logDir="${diagDir}/pod-logs-${clusterName}"
    mkdir -p "${logDir}"

    typeset -a components=(
        "daemonset/submariner-gateway"
        "daemonset/submariner-routeagent"
        "deployment/submariner-operator"
        "deployment/submariner-lighthouse-agent"
        "deployment/submariner-lighthouse-coredns"
    )

    typeset comp
    for comp in "${components[@]}"; do
        typeset safeComp="${comp//\//-}"
        {
            echo "=== logs for ${comp} on '${clusterName}' ==="
            KUBECONFIG="${kubeconfig}" oc logs "${comp}" \
                -n submariner-operator \
                --tail=200 \
                --prefix \
                2>&1 || true
        } > "${logDir}/${safeComp}.txt" || true
    done

    # Also dump previous logs in case the pod crashed
    for comp in "${components[@]}"; do
        typeset safeComp="${comp//\//-}"
        {
            echo "=== previous logs for ${comp} on '${clusterName}' ==="
            KUBECONFIG="${kubeconfig}" oc logs "${comp}" \
                -n submariner-operator \
                --tail=100 \
                --prefix \
                -p \
                2>&1 || true
        } > "${logDir}/${safeComp}-previous.txt" || true
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────
command -v oc 1>/dev/null || { : "oc not found — skipping Submariner diagnostics"; exit 0; }

mkdir -p "${diagDir}"

LoadSpokeConfig

if (( ${#spokeKubeconfigsArr[@]} == 0 )); then
    : "No spoke kubeconfigs found in SHARED_DIR — nothing to diagnose"
    exit 0
fi

InstallSubctl || { : "WARNING: subctl install failed — skipping subctl-based diagnostics"; }

: "=== Phase 1: oc-native Gateway CR dump and pod logs ==="
if [[ "${verifyHubSpoke}" == "true" ]]; then
    OcDumpGatewayStatus "${KUBECONFIG}" "hub"
    OcDumpPodLogs "${KUBECONFIG}" "hub"
fi

typeset -i i
for ((i = 0; i < ${#spokeKubeconfigsArr[@]}; i++)); do
    OcDumpGatewayStatus "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    OcDumpPodLogs "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
done

if [[ -x "${subctlBin}" ]]; then
    : "=== Phase 2: subctl show all ==="
    if [[ "${verifyHubSpoke}" == "true" ]]; then
        ShowAll "${KUBECONFIG}" "hub"
    fi
    for ((i = 0; i < ${#spokeKubeconfigsArr[@]}; i++)); do
        ShowAll "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    done

    : "=== Phase 3: subctl diagnose all ==="
    if [[ "${verifyHubSpoke}" == "true" ]]; then
        DiagnoseAll "${KUBECONFIG}" "hub"
    fi
    for ((i = 0; i < ${#spokeKubeconfigsArr[@]}; i++)); do
        DiagnoseAll "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    done

    : "=== Phase 4: subctl diagnose firewall inter-cluster ==="
    typeset mergedKc
    mergedKc="$(mktemp /tmp/kc-merged-diag-XXXXXX.json)"
    MergeKubeconfigs "${mergedKc}"

    # Hub ↔ each spoke
    if [[ "${verifyHubSpoke}" == "true" ]]; then
        for ((i = 0; i < ${#spokeKubeconfigsArr[@]}; i++)); do
            typeset spokeCtx="${spokeNamesArr[i]}-admin"
            DiagnoseFirewall "${mergedKc}" "hub-admin" "${spokeCtx}" \
                "hub-to-${spokeNamesArr[i]}"
        done
    fi

    # Spoke ↔ spoke pairs
    typeset -i j
    for ((i = 0; i < ${#spokeKubeconfigsArr[@]}; i++)); do
        for ((j = i + 1; j < ${#spokeKubeconfigsArr[@]}; j++)); do
            typeset ctx1="${spokeNamesArr[i]}-admin"
            typeset ctx2="${spokeNamesArr[j]}-admin"
            DiagnoseFirewall "${mergedKc}" "${ctx1}" "${ctx2}" \
                "${spokeNamesArr[i]}-to-${spokeNamesArr[j]}"
        done
    done

    : "=== Phase 5: subctl gather ==="
    GatherAll "${mergedKc}"

    rm -f "${mergedKc}"
fi

: "=== Submariner diagnostics complete. Artifacts saved to ${diagDir} ==="
ls -lh "${diagDir}" || true

# Always exit 0 — this is a post-step; failures must not block cluster teardown
exit 0
