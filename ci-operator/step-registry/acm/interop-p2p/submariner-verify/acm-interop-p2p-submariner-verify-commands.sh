#!/bin/bash
#
# Step 3 of 3: Submariner Connectivity Verification
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; only when SUBMARINER_RUN_SUBCTL_VERIFY=true)
#   - Show tunnel connection status on each spoke (and hub when SUBMARINER_VERIFY_HUB_SPOKE=true)
#   - Wait for all IPsec tunnels to reach "connected" state
#   - Apply CCLM sync ingress NetworkPolicy (after tunnels are confirmed connected)
#   - Assert no Globalnet subnets (242.x)
#   - Pre-warm the Lighthouse service-discovery pipeline before subctl verify
#   - Run 'subctl verify' when SUBMARINER_RUN_SUBCTL_VERIFY=true
#   - Probe bidirectional CCLM sync TCP paths (when SUBMARINER_VERIFY_CCLM_SYNC=true):
#       spoke↔spoke pairs (always, matching upstream main)
#       hub↔spoke (only when SUBMARINER_VERIFY_HUB_SPOKE=true)
#
# SPOKE CLUSTERS (spoke-to-spoke and hub-spoke jobs):
#   All spoke steps are identical to the upstream main branch.
#
# HUB CLUSTER (hub-spoke jobs only, SUBMARINER_VERIFY_HUB_SPOKE=true):
#   Hub-specific checks are added at each phase, gated by verifyHubSpoke.
#
# Globalnet is NOT used: warmup exports a Service and waits for ServiceImport
# plus EndpointSlice propagation (pod IPs), not GlobalIngressIP allocation.
#
# WHY subctl is optional:
#   subctl is large (~50 MB). When SUBMARINER_RUN_SUBCTL_VERIFY=false (default
#   for spoke-to-spoke jobs), subctl is not installed and functions that require
#   it (WarmUpServiceDiscovery, VerifyConnectivity) are skipped.  Gateway status
#   and tunnel checks via oc and CCLM sync probes run without subctl.
#
# WHY binaries are NOT stored in SHARED_DIR:
#   Kubernetes Secrets have a 3 MB limit; subctl exceeds it.  Each step installs
#   its own copy.
#

set -euxo pipefail; shopt -s inherit_errexit
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

# ── Constants ─────────────────────────────────────────────────────────────────
typeset -r subctlBin="/tmp/bin/subctl"
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"
typeset runSubctlVerify="${SUBMARINER_RUN_SUBCTL_VERIFY}"
typeset verifyHubSpoke="${SUBMARINER_VERIFY_HUB_SPOKE}"

typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()

# ── InstallSubctl — install subctl to /tmp/bin/ (only when opt-in) ───────────
InstallSubctl() {
    [[ "${runSubctlVerify}" == "true" ]] || return 0
    mkdir -p /tmp/bin
    if [[ -x "${subctlBin}" ]]; then
        return 0
    fi
    curl -Ls https://get.submariner.io | bash
    cp "${HOME}/.local/bin/subctl" "${subctlBin}"
    chmod +x "${subctlBin}"
    true
}

# ── LoadSpokeConfig — populate spoke arrays from SHARED_DIR ───────────────────
LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        [ -f "${kcFile}" ]
        [ -f "${nameFile}" ]

        spokeKubeconfigsArr+=("${kcFile}")
        spokeNamesArr+=("$(< "${nameFile}")")
    done
    true
}

# ── ShowConnections — display gateway tunnel status ───────────────────────────
ShowConnections() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterLabel="${1:-cluster}"; (($#)) && shift

    : "Gateway connections on '${clusterLabel}':"
    KUBECONFIG="${kubeconfig}" oc get gateways.submariner.io \
        -n submariner-operator -o wide || true

    if [[ "${runSubctlVerify}" == "true" && -x "${subctlBin}" ]]; then
        KUBECONFIG="${kubeconfig}" "${subctlBin}" show connections || true
    fi
    true
}

# ── WaitForConnectionsEstablished — poll until all tunnels show "connected" ───
# SPOKE PATH: identical to upstream main (polls only spoke gateways).
# HUB ADDITION: when verifyHubSpoke=true, also polls the hub gateway CR.
WaitForConnectionsEstablished() {
    typeset -i timeoutSecs="${1:-600}"; (($#)) && shift

    (
        typeset -i interval=15 allConnected
        SECONDS=0
        until (( SECONDS >= timeoutSecs )); do
            allConnected=1

            typeset -i i
            for ((i = 0; i < spokeCount; i++)); do
                typeset kubeconfig="${spokeKubeconfigsArr[i]}"
                typeset spokeName="${spokeNamesArr[i]}"

                typeset -i nonConnected
                nonConnected="$(
                    KUBECONFIG="${kubeconfig}" oc get gateways.submariner.io \
                        -n submariner-operator \
                        -o 'jsonpath-as-json={.items[?(@.status.haStatus=="active")].status.connections[*].status}' |
                    jq '[.[] | select(. != "connected")] | length'
                )"

                typeset -i totalConnections
                totalConnections="$(
                    KUBECONFIG="${kubeconfig}" oc get gateways.submariner.io \
                        -n submariner-operator \
                        -o 'jsonpath-as-json={.items[?(@.status.haStatus=="active")].status.connections[*].status}' |
                    jq 'length'
                )"

                : "spoke '${spokeName}': ${totalConnections} connection(s), ${nonConnected} not yet connected (${SECONDS}/${timeoutSecs}s)"

                if (( nonConnected > 0 || totalConnections == 0 )); then
                    allConnected=0
                fi
            done

            # Hub gateway check — hub is a full Submariner participant in hub↔spoke jobs.
            if [[ "${verifyHubSpoke}" == "true" ]]; then
                typeset -i hubNonConnected hubTotalConnections
                hubNonConnected="$(
                    oc get gateways.submariner.io \
                        -n submariner-operator \
                        -o 'jsonpath-as-json={.items[?(@.status.haStatus=="active")].status.connections[*].status}' |
                    jq '[.[] | select(. != "connected")] | length'
                )"
                hubTotalConnections="$(
                    oc get gateways.submariner.io \
                        -n submariner-operator \
                        -o 'jsonpath-as-json={.items[?(@.status.haStatus=="active")].status.connections[*].status}' |
                    jq 'length'
                )"
                : "hub: ${hubTotalConnections} connection(s), ${hubNonConnected} not yet connected (${SECONDS}/${timeoutSecs}s)"
                if (( hubNonConnected > 0 || hubTotalConnections == 0 )); then
                    allConnected=0
                fi
            fi

            if (( allConnected )); then
                : "All Submariner tunnels are connected"
                exit 0
            fi

            sleep "${interval}"
        done

        : "Submariner tunnels did not reach 'connected' on all clusters within ${timeoutSecs}s"
        typeset -i i
        for ((i = 0; i < spokeCount; i++)); do
            : "Connection status on '${spokeNamesArr[i]}'"
            [[ -x "${subctlBin}" ]] && \
                KUBECONFIG="${spokeKubeconfigsArr[i]}" "${subctlBin}" show connections || true
        done
        if [[ "${verifyHubSpoke}" == "true" && -x "${subctlBin}" ]]; then
            "${subctlBin}" show connections || true
        fi
        exit 1
    ) || return 1
}

# ── AllowCclmSyncIngress — NetworkPolicy: cross-cluster pod CIDRs → CNV port ──
# Creates (or updates) a NetworkPolicy in the CNV namespace on each cluster so
# that cross-cluster pod IPs (advertised by the Submariner gateway) are allowed
# to reach all pods in the namespace on SUBMARINER_CCLM_SYNC_PORT (default 8443).
#
# WHY THIS IS CALLED HERE (not in broker-join):
#   broker-join also attempts this but IPsec tunnels are not yet established at
#   that point, so gateways.submariner.io has no connection entries and the function
#   silently skips (no remote CIDRs).  By the time verify runs,
#   WaitForConnectionsEstablished has confirmed all tunnels are "connected" and
#   gateways.submariner.io contains full CIDR data.
#
# CRITICAL — WHY WE INCLUDE THE MACHINE NETWORK CIDR IN THE INGRESS ALLOW LIST:
#   Using `podSelector: {}` selects ALL pods in the CNV namespace.  In Kubernetes,
#   once any NetworkPolicy selects a pod via an Ingress rule, ALL ingress not
#   explicitly listed is DENIED.  The kube-apiserver runs in host-network on
#   control-plane nodes (not a pod CIDR), so adding only remote cluster CIDRs to
#   the allow list blocks kube-apiserver → cdi-apiserver and kube-apiserver →
#   virt-api on port 8443, breaking ALL CNV admission webhooks (DataVolume,
#   VirtualMachine mutators).  Including the local machine network CIDR ensures
#   control-plane host-network traffic is preserved.
AllowCclmSyncIngress() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset cnvNs="${SUBMARINER_CCLM_CNV_NAMESPACE:-openshift-cnv}"
    typeset cclmPort="${SUBMARINER_CCLM_SYNC_PORT:-8443}"

    # Collect remote pod/service CIDRs from active Submariner gateway connections.
    typeset -a allowCidrs=()
    typeset cidr
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        allowCidrs+=("${cidr}")
    done < <(
        KUBECONFIG="${kubeconfig}" oc get gateways.submariner.io \
            -n submariner-operator -o json 2>/dev/null \
            | jq -r '.items[].status.connections[].endpoint.subnets[]?' \
            || true
    )

    if (( ${#allowCidrs[@]} == 0 )); then
        : "No Submariner remote CIDRs found on '${clusterName}' — skipping CCLM NetworkPolicy"
        return 0
    fi

    # Also include the local machine network CIDR so that kube-apiserver
    # (running in host-network on control-plane nodes) can still reach
    # cdi-apiserver and virt-api webhooks on port 8443.
    typeset machineCidr
    machineCidr=$(KUBECONFIG="${kubeconfig}" oc get network.config.openshift.io cluster \
        -o jsonpath='{.spec.machineNetwork[0].cidr}' 2>/dev/null || true)
    if [[ -n "${machineCidr}" ]]; then
        : "Including machine network CIDR '${machineCidr}' to preserve kube-apiserver webhook access"
        allowCidrs+=("${machineCidr}")
    else
        : "WARNING: could not read machine network CIDR — kube-apiserver webhook access may be blocked"
    fi

    : "Creating CCLM ingress NetworkPolicy on '${clusterName}' ns='${cnvNs}' port=${cclmPort} cidrs=[${allowCidrs[*]}]"

    KUBECONFIG="${kubeconfig}" oc apply -f - < <(
        jq -n \
            --arg  ns   "${cnvNs}" \
            --arg  port "${cclmPort}" \
            --argjson cidrs "$(printf '%s\n' "${allowCidrs[@]}" | jq -R . | jq -s .)" \
            '{
                apiVersion: "networking.k8s.io/v1",
                kind: "NetworkPolicy",
                metadata: {name: "allow-submariner-cclm-sync", namespace: $ns},
                spec: {
                    podSelector: {},
                    policyTypes: ["Ingress"],
                    ingress: [{
                        from: ($cidrs | map({ipBlock: {cidr: .}})),
                        ports: [{protocol: "TCP", port: ($port | tonumber)}]
                    }]
                }
            }'
    ) || {
        : "WARNING: could not apply CCLM sync NetworkPolicy on '${clusterName}' (ns may not exist yet)"
        true
    }
}

# ── AssertNoGlobalnetSubnets — fail if Globalnet 242.x routes are advertised ──
# Uses oc to read gateway endpoint subnets — no subctl needed.
# Uses _gnFailed tracking: explicit failure propagation in ( ) || ... context.
AssertNoGlobalnetSubnets() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset -i _gnFailed=0

    typeset remoteSubnets
    remoteSubnets="$(
        KUBECONFIG="${kubeconfig}" oc get gateways.submariner.io \
            -n submariner-operator -o json \
            | jq -r '.items[].status.connections[].endpoint.subnets[]?' || true
    )"

    if grep -E '^242\.' <<< "${remoteSubnets}"; then
        : "Globalnet subnets (242.x.x.x) in gateway connections on '${clusterName}' — incompatible with CCLM"
        _gnFailed=1
    fi

    if [[ "${runSubctlVerify}" == "true" && -x "${subctlBin}" ]]; then
        typeset connOutput
        connOutput="$(KUBECONFIG="${kubeconfig}" "${subctlBin}" show connections || true)"
        if grep -E '242\.[0-9]+\.[0-9]+\.[0-9]+' <<< "${connOutput}"; then
            : "Globalnet subnets (242.x.x.x) via subctl on '${clusterName}' — incompatible with CCLM"
            _gnFailed=1
        fi
    fi

    if (( _gnFailed == 0 )); then
        : "No Globalnet subnets on '${clusterName}'"
    fi
    (( _gnFailed == 0 ))
}

# ── WarmUpServiceDiscovery — prime Lighthouse before verify (no Globalnet) ────
# Requires subctl ('subctl export service'). Skip entirely when
# SUBMARINER_RUN_SUBCTL_VERIFY=false to avoid 300s polling loop timeouts caused
# by calling a missing /tmp/bin/subctl binary.
WarmUpServiceDiscovery() {
    [[ "${runSubctlVerify}" == "true" ]] || return 0
    typeset kcSource="${1:?}"; (($#)) && shift
    typeset kcTarget="${1:?}"; (($#)) && shift
    typeset srcName="${1:?}"; (($#)) && shift
    typeset tgtName="${1:?}"; (($#)) && shift

    typeset warmupNs="submariner-warmup"

    for kc in "${kcSource}" "${kcTarget}"; do
        (
            typeset -i nsMax=120 nsInterval=5
            SECONDS=0
            while KUBECONFIG="${kc}" oc get namespace "${warmupNs}" \
                    -o jsonpath='{.status.phase}' | grep -q Terminating; do
                if (( SECONDS >= nsMax )); then
                    : "Namespace '${warmupNs}' stuck in Terminating — force-clearing"
                    KUBECONFIG="${kc}" oc patch namespace "${warmupNs}" \
                        -p '{"spec":{"finalizers":null}}' --type=merge || true
                fi
                sleep "${nsInterval}"
            done
            true
        )

        KUBECONFIG="${kc}" oc create namespace "${warmupNs}" \
            --dry-run=client -o yaml --save-config | KUBECONFIG="${kc}" oc apply -f - 1>/dev/null
    done

    KUBECONFIG="${kcSource}" oc apply -f - 1>/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: warmup-nginx
  namespace: ${warmupNs}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: warmup-nginx
  template:
    metadata:
      labels:
        app: warmup-nginx
    spec:
      containers:
      - name: nginx
        # nginxinc/nginx-unprivileged is accessible in CI clusters via the
        # Docker Hub mirror configured in the cluster pull-secret.
        image: nginxinc/nginx-unprivileged:stable-alpine
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: warmup-nginx
  namespace: ${warmupNs}
spec:
  ipFamilyPolicy: SingleStack
  ipFamilies: [IPv4]
  selector:
    app: warmup-nginx
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
  type: ClusterIP
EOF

    KUBECONFIG="${kcSource}" oc wait deployment/warmup-nginx \
        -n "${warmupNs}" \
        --for=condition=Available \
        --timeout=3m 1>/dev/null

    KUBECONFIG="${kcSource}" "${subctlBin}" export service \
        -n "${warmupNs}" warmup-nginx

    (
        typeset -i siExistMax=300 siExistInterval=10
        SECONDS=0
        until KUBECONFIG="${kcTarget}" oc get serviceimport warmup-nginx \
                -n "${warmupNs}" 1>/dev/null; do
            if (( SECONDS >= siExistMax )); then
                : "ServiceImport warmup-nginx not found on '${tgtName}' after ${siExistMax}s"
                KUBECONFIG="${kcTarget}" oc get serviceimports -A || true
                KUBECONFIG="${kcTarget}" oc logs deployment/submariner-lighthouse-agent \
                    -n submariner-operator --tail=30 || true
                exit 1
            fi
            sleep "${siExistInterval}"
        done
    ) || return 1

    (
        typeset -i esMax=300 esInterval=10
        typeset esAddr=""
        SECONDS=0
        until [[ -n "${esAddr}" ]]; do
            if (( SECONDS >= esMax )); then
                : "EndpointSlice for warmup-nginx has no addresses on '${tgtName}' after ${esMax}s"
                KUBECONFIG="${kcTarget}" oc get endpointslices -n "${warmupNs}" -o wide || true
                KUBECONFIG="${kcTarget}" oc get serviceimport warmup-nginx \
                    -n "${warmupNs}" -o yaml || true
                exit 1
            fi
            esAddr="$(KUBECONFIG="${kcTarget}" oc get endpointslices \
                -n "${warmupNs}" \
                -l multicluster.kubernetes.io/service-name=warmup-nginx \
                -o jsonpath='{.items[*].endpoints[*].addresses[*]}' \
                || true)"
            if [[ -z "${esAddr}" ]]; then
                sleep "${esInterval}"
            fi
        done
        : "Service-discovery warmup complete: EndpointSlice address '${esAddr}' visible on '${tgtName}'"
    ) || return 1

    KUBECONFIG="${kcSource}" oc delete namespace "${warmupNs}" \
        --ignore-not-found 1>/dev/null &
    KUBECONFIG="${kcTarget}" oc delete namespace "${warmupNs}" \
        --ignore-not-found 1>/dev/null &
}

# ── GetSyncControllerPodIp — first Running virt-synchronization-controller pod IP ─
GetSyncControllerPodIp() {
    typeset kubeconfig="${1:?}"; (($#)) && shift

    KUBECONFIG="${kubeconfig}" oc get pods -n "${SUBMARINER_CCLM_CNV_NAMESPACE}" -o json \
        | jq -r 'first(
            .items[]
            | select(.metadata.name | startswith("virt-synchronization-controller"))
            | select(.status.phase == "Running")
            | select((.status.podIP // "") != "")
            | .status.podIP
        )'
}

# ── ProbeCclmSyncPort — TCP probe to sync-controller pod IP:8443 ──────────────
# Does NOT use `oc run --rm -i` because `-i` masks non-zero container exit codes
# in some oc versions — the pod terminates with Error but oc returns 0.
# Instead: creates pod without --rm, waits for Succeeded phase via `oc wait`,
# then reads exit code from pod status before cleanup.
#
# NAMESPACE CHOICE — submariner-operator (not a freshly-created namespace):
#   OVN-K programs cross-cluster PBR rules per namespace. A brand-new namespace
#   gets PBR rules only after OVN reconciles the new logical switch (several seconds).
#   A probe pod in a fresh namespace can race against this reconciliation and miss
#   the Submariner gateway route (exit 124) even though the IPsec tunnel is up.
#   Using 'submariner-operator' — an existing namespace — guarantees OVN-K has
#   already programmed the cross-cluster PBR rules. Only the probe pod is deleted.
ProbeCclmSyncPort() {
    typeset srcKubeconfig="${1:?}"; (($#)) && shift
    typeset destIp="${1:?}"; (($#)) && shift
    typeset probeLabel="${1:?}"; (($#)) && shift

    typeset -r probeNs="submariner-operator"
    typeset probePod="cclm-sync-probe-${probeLabel}"

    # Remove any stale pod from a prior run.
    KUBECONFIG="${srcKubeconfig}" oc delete pod "${probePod}" \
        -n "${probeNs}" --ignore-not-found --wait=true --timeout=30s 1>/dev/null 2>&1 || true

    # Create probe pod without --rm so we can read its exit code from status.
    KUBECONFIG="${srcKubeconfig}" oc run "${probePod}" \
        -n "${probeNs}" \
        --restart=Never \
        --image=registry.redhat.io/ubi9/ubi-minimal:latest \
        --command -- \
        timeout "${SUBMARINER_CCLM_SYNC_PROBE_TIMEOUT}" bash -c \
            "echo >/dev/tcp/${destIp}/${SUBMARINER_CCLM_SYNC_PORT}" \
        1>/dev/null

    # Wait for pod to reach Succeeded (probe timeout + 60s scheduling buffer).
    typeset -i waitSecs=$(( SUBMARINER_CCLM_SYNC_PROBE_TIMEOUT + 60 ))
    KUBECONFIG="${srcKubeconfig}" oc wait "pod/${probePod}" \
        -n "${probeNs}" \
        --for=jsonpath='{.status.phase}'=Succeeded \
        --timeout="${waitSecs}s" 1>/dev/null 2>&1 || true

    # Read pod phase and container exit code reliably from pod status.
    typeset phase exitCode
    phase="$(KUBECONFIG="${srcKubeconfig}" oc get "pod/${probePod}" \
        -n "${probeNs}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown')"
    exitCode="$(KUBECONFIG="${srcKubeconfig}" oc get "pod/${probePod}" \
        -n "${probeNs}" \
        -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' \
        2>/dev/null || echo '1')"

    # Delete only the probe pod; leave the submariner-operator namespace untouched.
    KUBECONFIG="${srcKubeconfig}" oc delete pod "${probePod}" \
        -n "${probeNs}" --ignore-not-found --wait=false 1>/dev/null &

    if [[ "${phase}" != "Succeeded" || "${exitCode}" != "0" ]]; then
        : "CCLM sync probe FAILED → ${destIp}:${SUBMARINER_CCLM_SYNC_PORT} (phase=${phase}, exitCode=${exitCode:-unknown})" >&2
        return 1
    fi
    true
}

# ── VerifyCclmSyncPath — bidirectional sync-controller TCP reachability ───────
# Uses _probesFailed tracking so both directions are always attempted before
# returning failure (better diagnostics when one direction is broken).
VerifyCclmSyncPath() {
    typeset kcSource="${1:?}"; (($#)) && shift
    typeset kcTarget="${1:?}"; (($#)) && shift
    typeset srcName="${1:?}"; (($#)) && shift
    typeset tgtName="${1:?}"; (($#)) && shift

    [[ "${SUBMARINER_VERIFY_CCLM_SYNC}" == "true" ]] || return 0

    typeset srcSyncIp tgtSyncIp
    srcSyncIp="$(GetSyncControllerPodIp "${kcSource}")"
    tgtSyncIp="$(GetSyncControllerPodIp "${kcTarget}")"

    [[ -n "${srcSyncIp}" ]] || {
        : "No Running virt-synchronization-controller pod IP on '${srcName}'"
        return 1
    }
    [[ -n "${tgtSyncIp}" ]] || {
        : "No Running virt-synchronization-controller pod IP on '${tgtName}'"
        return 1
    }

    # Run both probe directions before returning — explicit tracking ensures
    # both results are logged even when the first probe fails.
    typeset -i _probesFailed=0

    : "CCLM sync probe ${srcName} -> ${tgtName} (${tgtSyncIp}:${SUBMARINER_CCLM_SYNC_PORT})"
    ProbeCclmSyncPort "${kcSource}" "${tgtSyncIp}" "${srcName}-to-${tgtName}" \
        || _probesFailed=1

    : "CCLM sync probe ${tgtName} -> ${srcName} (${srcSyncIp}:${SUBMARINER_CCLM_SYNC_PORT})"
    ProbeCclmSyncPort "${kcTarget}" "${srcSyncIp}" "${tgtName}-to-${srcName}" \
        || _probesFailed=1

    (( _probesFailed == 0 ))
}

# ── VerifyConnectivity — run subctl verify between two clusters (opt-in) ──────
# Skipped when SUBMARINER_RUN_SUBCTL_VERIFY=false (subctl not installed).
VerifyConnectivity() {
    typeset kc1="${1:?}"; (($#)) && shift
    typeset kc2="${1:?}"; (($#)) && shift
    typeset name1="${1:?}"; (($#)) && shift
    typeset name2="${1:?}"; (($#)) && shift

    [[ "${runSubctlVerify}" == "true" ]] || {
        : "Skipping subctl verify for '${name1}↔${name2}' (SUBMARINER_RUN_SUBCTL_VERIFY=false)"
        return 0
    }

    typeset ctx1="${name1}-admin"
    typeset ctx2="${name2}-admin"

    typeset kc1Renamed kc2Renamed mergedKc
    kc1Renamed="$(mktemp /tmp/kc1-XXXXXX.json)"
    kc2Renamed="$(mktemp /tmp/kc2-XXXXXX.json)"
    mergedKc="$(mktemp /tmp/kc-merged-XXXXXX.json)"

    KUBECONFIG="${kc1}" oc config view -o json --raw | \
        jq \
            --arg ctx "${ctx1}" \
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
            --arg ctx "${ctx2}" \
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

    KUBECONFIG="${mergedKc}" "${subctlBin}" verify \
        --context   "${ctx1}" \
        --tocontext "${ctx2}" \
        --only connectivity,service-discovery \
        --verbose
    typeset -i rc=$?

    rm -f "${kc1Renamed}" "${kc2Renamed}" "${mergedKc}"
    return "${rc}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
command -v oc 1>/dev/null
[[ "${runSubctlVerify}" == "true" ]] && command -v curl 1>/dev/null

LoadSpokeConfig
InstallSubctl

typeset -i submarinerStepRc=0
(
    # bash set -e is suppressed inside ( ... ) || ... — use explicit || _stepFailed=1
    # on every critical call and make (( _stepFailed == 0 )) the LAST command so
    # the subshell exit code accurately reflects any failure.
    typeset -i _stepFailed=0
    typeset -i i j

    # ── Show initial gateway status ───────────────────────────────────────────
    for ((i = 0; i < spokeCount; i++)); do
        ShowConnections "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    done
    if [[ "${verifyHubSpoke}" == "true" && -r "${KUBECONFIG}" ]]; then
        ShowConnections "${KUBECONFIG}" "hub"
    fi

    # ── Wait for all tunnels to be connected ──────────────────────────────────
    WaitForConnectionsEstablished 600 || _stepFailed=1

    # ── Apply CCLM sync ingress NetworkPolicy (after tunnels confirmed up) ────
    # Best-effort: a missing openshift-cnv namespace must not block verification.
    for ((i = 0; i < spokeCount; i++)); do
        AllowCclmSyncIngress "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    done
    if [[ "${verifyHubSpoke}" == "true" && -r "${KUBECONFIG}" ]]; then
        AllowCclmSyncIngress "${KUBECONFIG}" "hub"
    fi

    # ── Assert no Globalnet subnets ───────────────────────────────────────────
    for ((i = 0; i < spokeCount; i++)); do
        AssertNoGlobalnetSubnets \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _stepFailed=1
    done
    if [[ "${verifyHubSpoke}" == "true" && -r "${KUBECONFIG}" ]]; then
        AssertNoGlobalnetSubnets "${KUBECONFIG}" "hub" || _stepFailed=1
    fi

    # ── Service-discovery warmup (spoke↔spoke) ────────────────────────────────
    for ((i = 0; i < spokeCount; i++)); do
        for ((j = i + 1; j < spokeCount; j++)); do
            WarmUpServiceDiscovery \
                "${spokeKubeconfigsArr[i]}" \
                "${spokeKubeconfigsArr[j]}" \
                "${spokeNamesArr[i]}" \
                "${spokeNamesArr[j]}"
        done
    done

    # ── Service-discovery warmup (hub↔spoke) ──────────────────────────────────
    if [[ "${verifyHubSpoke}" == "true" && -r "${KUBECONFIG}" ]]; then
        for ((i = 0; i < spokeCount; i++)); do
            WarmUpServiceDiscovery \
                "${KUBECONFIG}" \
                "${spokeKubeconfigsArr[i]}" \
                "hub" \
                "${spokeNamesArr[i]}"
        done
    fi

    # ── subctl verify + CCLM sync probe (spoke↔spoke) ─────────────────────────
    for ((i = 0; i < spokeCount; i++)); do
        for ((j = i + 1; j < spokeCount; j++)); do
            VerifyConnectivity \
                "${spokeKubeconfigsArr[i]}" \
                "${spokeKubeconfigsArr[j]}" \
                "${spokeNamesArr[i]}" \
                "${spokeNamesArr[j]}" \
                || _stepFailed=1
            VerifyCclmSyncPath \
                "${spokeKubeconfigsArr[i]}" \
                "${spokeKubeconfigsArr[j]}" \
                "${spokeNamesArr[i]}" \
                "${spokeNamesArr[j]}" \
                || _stepFailed=1
        done
    done

    # ── subctl verify + CCLM sync probe (hub↔spoke) ───────────────────────────
    if [[ "${verifyHubSpoke}" == "true" && -r "${KUBECONFIG}" ]]; then
        for ((i = 0; i < spokeCount; i++)); do
            VerifyConnectivity \
                "${KUBECONFIG}" \
                "${spokeKubeconfigsArr[i]}" \
                "hub" \
                "${spokeNamesArr[i]}" \
                || _stepFailed=1
            VerifyCclmSyncPath \
                "${KUBECONFIG}" \
                "${spokeKubeconfigsArr[i]}" \
                "hub" \
                "${spokeNamesArr[i]}" \
                || _stepFailed=1
        done
    fi

    # ── Final gateway connection status ───────────────────────────────────────
    : "Final gateway connection status"
    for ((i = 0; i < spokeCount; i++)); do
        ShowConnections "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    done
    if [[ "${verifyHubSpoke}" == "true" && -r "${KUBECONFIG}" ]]; then
        ShowConnections "${KUBECONFIG}" "hub"
    fi

    # LAST command: propagate any failure as the subshell exit code.
    (( _stepFailed == 0 ))
) || submarinerStepRc=$?

if (( submarinerStepRc != 0 )); then
    : "acm-interop-p2p-submariner-verify failed (rc=${submarinerStepRc})"
    [[ "${SUBMARINER_VERIFY_DEBUG_MODE}" == "true" ]] || exit "${submarinerStepRc}"
    : "SUBMARINER_VERIFY_DEBUG_MODE=true — not failing job"
fi
true
