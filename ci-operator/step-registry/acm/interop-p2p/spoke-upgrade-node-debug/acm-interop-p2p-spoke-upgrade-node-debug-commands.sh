#!/bin/bash
#
# Post-step: gather spoke node OS-upgrade diagnostics.
#
# Runs in the POST phase (always, regardless of test outcome).  Targets nodes
# stuck in an RHCOS update (rpm-ostree rebase timeout / MachineConfigDaemonPivotError).
# Coverage mapped to the four known root causes:
#
#   Cause 1 — Image download after drain (OCPBUGS-87861)
#     MCO does not pre-cache the RHCOS image; download only begins after drain.
#     Slow or constrained network can exhaust the pivot timeout.
#     → rpm-ostreed-journal.txt: look for pull start time vs timeout
#
#   Cause 2 — Network / registry connectivity (quay.io pull failure)
#     Firewall, proxy, TLS, or interface issues halt the pivot.
#     MachineConfigDaemonPivotError alert fires if pivot does not complete in ~2m.
#     → network-check.txt, rpm-ostreed-journal.txt
#
#   Cause 3 — DNS race condition (OCPBUGS-43406)
#     CoreDNS static pod update collides with rpm-ostree rebase.
#     → dns-journal.txt, coredns-pods.txt, resolv-conf.txt
#
#   Cause 4 — DBUS / rpm-ostreed stuck (OCPBUGS-7248)
#     Stuck rpm-ostreed process or DBUS timeout → "Transaction in progress" errors.
#     → dbus-journal.txt, rpm-ostree-status.txt, mcd-force-flag.txt
#
# Always exits 0 — must not mask the real test failure (EXIT trap overrides).
# Skips gracefully if managed-cluster-kubeconfig is absent.
#
# Artifacts: ${ARTIFACT_DIR}/spoke-node-upgrade-debug/
#
set -euxo pipefail; shopt -s inherit_errexit

# EXIT trap: always exit 0 — this is a diagnostic post-step, not a gate.
# Any unexpected errexit still triggers this trap, so the job result is never
# masked by a failure inside this script.
trap 'exit 0' EXIT

# ─── Setup ──────────────────────────────────────────────────────────────────

if [[ ! -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
    : "SKIP: ${SHARED_DIR}/managed-cluster-kubeconfig not found — spoke may not have been provisioned"
    exit 0
fi

export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

# proxy-conf.sh may export HTTPS_PROXY=http://user:pass@... — disable xtrace so
# the assignment is not traced into CI logs; re-enable immediately after.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    set +x
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
    set -x
fi

typeset artifactDir="${ARTIFACT_DIR}/spoke-node-upgrade-debug"
mkdir -p "${artifactDir}"

typeset spokeName='spoke'
if [[ -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    spokeName="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")"
    [[ -n "${spokeName}" ]] || spokeName='spoke'
fi

: "Spoke node OS-upgrade diagnostics — ${spokeName}"
: "RCA coverage: OCPBUGS-87861 (pre-cache), OCPBUGS-43406 (DNS), OCPBUGS-7248 (dbus)"
: "Artifacts → ${artifactDir}/"

# ─── Helper ─────────────────────────────────────────────────────────────────

# Collect — run a command, write stdout+stderr to file; xtrace shows the command.
# The line-count marker is surfaced via `: "..."` so it appears exactly once in xtrace.
Collect() {
    typeset outFile="$1"; shift
    "$@" > "${outFile}" 2>&1 || true
    : "$(wc -l < "${outFile}") lines → $(basename "${outFile}")"
    true
}

# ─── Cluster-level snapshot ──────────────────────────────────────────────────

Collect "${artifactDir}/nodes-wide.txt" \
    oc get nodes -o wide

Collect "${artifactDir}/machineconfigpools.txt" \
    oc get machineconfigpools \
        -o custom-columns=\
'NAME:metadata.name,'\
'UPDATED:status.conditions[?(@.type=="Updated")].status,'\
'UPDATING:status.conditions[?(@.type=="Updating")].status,'\
'DEGRADED:status.conditions[?(@.type=="Degraded")].status,'\
'DEGRADED_COUNT:status.degradedMachineCount,'\
'MACHINE_COUNT:status.machineCount,'\
'READY_COUNT:status.readyMachineCount,'\
'DESIRED_CONFIG:spec.configuration.name'

Collect "${artifactDir}/machineconfigs.txt" \
    oc get machineconfigs -o wide

Collect "${artifactDir}/mco-pods.txt" \
    oc get pods -n openshift-machine-config-operator -o wide

Collect "${artifactDir}/mco-operator-logs.txt" \
    oc logs -n openshift-machine-config-operator \
        -l k8s-app=machine-config-operator \
        --tail=500

# Cause 3 (OCPBUGS-43406): CoreDNS restart count — elevated restarts = DNS race
Collect "${artifactDir}/coredns-pods.txt" \
    oc get pods -n openshift-dns -o wide

Collect "${artifactDir}/coredns-configmap.txt" \
    oc get configmap -n openshift-dns dns-default -o yaml

# ─── Node machineconfig annotation diff ─────────────────────────────────────

# Show all worker nodes with their currentConfig vs desiredConfig annotations.
# A mismatch immediately identifies which node(s) are stuck.
typeset annotFile="${artifactDir}/node-mc-annotations.txt"
{
    printf '%-50s %-65s %-65s\n' 'NODE' 'CURRENT-CONFIG' 'DESIRED-CONFIG'
    printf '%s\n' "$(printf '%.0s-' {1..180})"
    oc get nodes -o json 2>/dev/null | \
        jq -r '.items[] | [
            .metadata.name,
            (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "N/A"),
            (.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"]  // "N/A")
        ] | @tsv' | \
        awk -F'\t' '{ printf "%-50s %-65s %-65s\n", $1, $2, $3 }' || true
} > "${annotFile}" 2>&1 || true

# Print to console (not echo — cat content is not doubled by xtrace)
cat "${annotFile}"

# ─── Identify stuck nodes ────────────────────────────────────────────────────

typeset -a stuckNodes=()

# Config-mismatch: currentConfig annotation != desiredConfig annotation
while read -r nodeName currentCfg desiredCfg; do
    [[ -n "${nodeName}" ]] || continue
    [[ "${currentCfg}" != "${desiredCfg}" ]] || continue
    stuckNodes+=("${nodeName}")
done < <(
    oc get nodes -o json 2>/dev/null | \
        jq -r '.items[] | [
            .metadata.name,
            (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // ""),
            (.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"]  // "")
        ] | @tsv' || true
)

# SchedulingDisabled nodes (MCD cordoned them for update but never uncordoned)
typeset alreadyListed
while read -r nodeName _; do
    [[ -n "${nodeName}" ]] || continue
    alreadyListed=false
    typeset n
    for n in "${stuckNodes[@]+"${stuckNodes[@]}"}"; do
        [[ "${n}" == "${nodeName}" ]] && { alreadyListed=true; break; }
    done
    [[ "${alreadyListed}" == "true" ]] || stuckNodes+=("${nodeName}")
done < <(
    oc get nodes --no-headers 2>/dev/null | awk '/SchedulingDisabled/ {print $1}' || true
)

if [[ ${#stuckNodes[@]} -eq 0 ]]; then
    : "No stuck nodes — all currentConfig == desiredConfig, no SchedulingDisabled nodes"
    exit 0
fi

: "Stuck node(s): ${stuckNodes[*]}"

# ─── Per-node diagnostics ────────────────────────────────────────────────────

typeset nodeName
for nodeName in "${stuckNodes[@]}"; do

    : "=== Collecting diagnostics for stuck node: ${nodeName} ==="

    typeset nodeDir="${artifactDir}/node-${nodeName}"
    mkdir -p "${nodeDir}"

    Collect "${nodeDir}/describe.txt" \
        oc describe node "${nodeName}"

    # Cause 1 + 2: rpm-ostreed journal — image pull timing, timeout, registry errors.
    # Look for: rebase start time, image pull duration, "Timeout" or registry TLS errors.
    Collect "${nodeDir}/rpm-ostreed-journal.txt" \
        oc adm node-logs "${nodeName}" \
            --unit rpm-ostreed \
            --since="-6h"

    # Pivot alert evidence (MachineConfigDaemonPivotError fires within ~2m of pivot start)
    Collect "${nodeDir}/mco-alerts.txt" \
        oc get prometheusrule -n openshift-machine-config-operator -o yaml

    # Cause 3: DNS journals on the stuck node (OCPBUGS-43406)
    # Look for: DNS lookup failures during rebase, NXDOMAIN, connection refused to DNS server
    Collect "${nodeDir}/dns-journal.txt" \
        oc adm node-logs "${nodeName}" \
            --unit coreDNS \
            --since="-6h"

    # DNS resolver config in effect on the node during upgrade
    Collect "${nodeDir}/resolv-conf.txt" \
        oc adm node-logs "${nodeName}" \
            --path=/etc/resolv.conf

    # Cause 4: DBUS journal (OCPBUGS-7248)
    # Look for: "Transaction in progress", "Start request repeated too quickly"
    Collect "${nodeDir}/dbus-journal.txt" \
        oc adm node-logs "${nodeName}" \
            --unit dbus \
            --since="-6h"

    # MCD journal on the node — state transitions: Applying → Rebooting → Degraded
    Collect "${nodeDir}/machine-config-daemon-journal.txt" \
        oc adm node-logs "${nodeName}" \
            --unit machine-config-daemon \
            --since="-6h"

    # kubelet journal — reboot attempts and node rejoin timing
    Collect "${nodeDir}/kubelet-journal.txt" \
        oc adm node-logs "${nodeName}" \
            --unit kubelet \
            --since="-6h" \
            --tail=500

    # MCD pod — contains the definitive "Failed to update OS after retries" message
    typeset mcdPod
    mcdPod="$(
        oc get pods -n openshift-machine-config-operator \
            -l k8s-app=machine-config-daemon \
            --field-selector "spec.nodeName=${nodeName}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
    )"

    if [[ -n "${mcdPod}" && "${mcdPod}" != "null" ]]; then

        Collect "${nodeDir}/mcd-pod-logs.txt" \
            oc logs -n openshift-machine-config-operator "${mcdPod}" \
                --all-containers --tail=2000

        # Cause 4: live rpm-ostree status (MCD pod runs privileged with host PID namespace)
        # Look for: stuck pending deployment, "Transaction in progress", unpinned refs
        Collect "${nodeDir}/rpm-ostree-status.txt" \
            oc exec -n openshift-machine-config-operator "${mcdPod}" \
                -- chroot /rootfs rpm-ostree status --verbose

        # Cause 4: presence/absence of the force-retry flag
        # If absent → MCD never received a force-retry signal
        Collect "${nodeDir}/mcd-force-flag.txt" \
            oc exec -n openshift-machine-config-operator "${mcdPod}" \
                -- ls -la /rootfs/run/machine-config-daemon-force

        # Cause 2: network reachability to quay.io from inside the node.
        # The MCD pod shares the node's network namespace.
        # NOTE: -v flag intentionally omitted — verbose curl output includes proxy
        # auth headers (Authorization: Proxy user:pass) which must not go to artifacts.
        # -sS: silent but show errors; -w: structured timing output; -o /dev/null: discard body.
        Collect "${nodeDir}/network-check.txt" \
            oc exec -n openshift-machine-config-operator "${mcdPod}" \
                -- curl -sSL \
                    --connect-timeout 10 \
                    --max-time 20 \
                    -w 'HTTP %{response_code} | connect %.3fs | total %.3fs\n' \
                    -o /dev/null \
                    https://quay.io/v2/

    else
        : "No machine-config-daemon pod found for ${nodeName} — exec-based collection skipped"
        printf '%s\n' "(no mcd pod found for ${nodeName})" \
            > "${nodeDir}/mcd-pod-logs.txt"
        printf '%s\n' "(no mcd pod — exec skipped)" \
            > "${nodeDir}/rpm-ostree-status.txt"
        printf '%s\n' "(no mcd pod — exec skipped)" \
            > "${nodeDir}/network-check.txt"
        printf '%s\n' "(no mcd pod — exec skipped)" \
            > "${nodeDir}/mcd-force-flag.txt"
    fi

    : "=== Done: ${nodeName} → ${nodeDir}/ ==="
done

# Write summary to artifact (not echoed to console — xtrace of cat is sufficient)
cat > "${artifactDir}/SUMMARY.txt" <<SUMMARY_EOF
Spoke node OS-upgrade diagnostics — ${spokeName}
Stuck node(s): ${stuckNodes[*]}

Key artifacts per stuck node  (node-<name>/):
  rpm-ostreed-journal.txt        Cause 1+2: image pull timing / timeout / registry errors
  dbus-journal.txt               Cause 4 (OCPBUGS-7248): "Transaction in progress"
  dns-journal.txt + resolv-conf  Cause 3 (OCPBUGS-43406): DNS lookup failures
  mcd-pod-logs.txt               "Failed to update OS after retries: timed out"
  rpm-ostree-status.txt          Cause 4: current deployment state / stuck pending
  mcd-force-flag.txt             Cause 4: /run/machine-config-daemon-force absent → no retry
  network-check.txt              Cause 2: HTTP response code + timing from node to quay.io

Manual recovery on stuck node (Cause 4):
  systemctl restart rpm-ostreed
  touch /run/machine-config-daemon-force
SUMMARY_EOF

true
