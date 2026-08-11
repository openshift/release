#!/bin/bash
#
# Step 3 of 3: Submariner Connectivity Verification
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Show tunnel connection status on each spoke
#   - Wait for all IPsec tunnels to reach "connected" state
#   - Pre-warm the Lighthouse service-discovery pipeline before subctl verify
#   - Run 'subctl verify' for connectivity and service-discovery tests
#
# Globalnet is NOT used: warmup exports a Service and waits for ServiceImport
# plus EndpointSlice propagation (pod IPs), not GlobalIngressIP allocation.
#
# WHY subctl is downloaded here (not read from SHARED_DIR):
#   Storing large binaries in SHARED_DIR causes CI operator to fail with
#   "Request entity too large" when serialising SHARED_DIR into a Kubernetes
#   Secret between steps (3 MB limit).  Each step installs its own copy.
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

typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()

# ── InstallSubctl — install subctl to /tmp/bin/ ───────────────────────────────
InstallSubctl() {
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

# ── ShowConnections — display tunnel connection status on one spoke ───────────
ShowConnections() {
    typeset kubeconfig="${1:?}"; (($#)) && shift

    KUBECONFIG="${kubeconfig}" "${subctlBin}" show connections || true
    true
}

# ── WaitForConnectionsEstablished — poll until all tunnels show "connected" ───
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

            if (( allConnected )); then
                : "All Submariner tunnels are connected"
                exit 0
            fi

            sleep "${interval}"
        done

        : "Submariner tunnels did not reach 'connected' on all spokes within ${timeoutSecs}s"
        typeset -i i
        for ((i = 0; i < spokeCount; i++)); do
            : "Connection status on '${spokeNamesArr[i]}'"
            KUBECONFIG="${spokeKubeconfigsArr[i]}" "${subctlBin}" show connections || true
        done
        exit 1
    )
    true
}

# ── WarmUpServiceDiscovery — prime Lighthouse before verify (no Globalnet) ────
WarmUpServiceDiscovery() {
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
        true
    )

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
        true
    )

    KUBECONFIG="${kcSource}" oc delete namespace "${warmupNs}" \
        --ignore-not-found 1>/dev/null &
    KUBECONFIG="${kcTarget}" oc delete namespace "${warmupNs}" \
        --ignore-not-found 1>/dev/null &

    true
}

# ── AssertNoGlobalnetSubnets — fail if Globalnet 242.x routes are advertised ──
AssertNoGlobalnetSubnets() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset connOutput
    connOutput="$(KUBECONFIG="${kubeconfig}" "${subctlBin}" show connections || true)"

    if grep -E '242\.[0-9]+\.[0-9]+\.[0-9]+' <<< "${connOutput}"; then
        : "Globalnet subnets (242.x.x.x) advertised on '${spokeName}' — incompatible with CCLM pod IP sync"
        false
    fi

    true
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

# ── ProbeCclmSyncPort — TCP probe to sync-controller pod IP:8443 from a spoke ─
ProbeCclmSyncPort() {
    typeset srcKubeconfig="${1:?}"; (($#)) && shift
    typeset destIp="${1:?}"; (($#)) && shift
    typeset probeLabel="${1:?}"; (($#)) && shift

    typeset -r probeNs="submariner-cclm-probe"
    typeset probePod="cclm-sync-probe-${probeLabel}"

    KUBECONFIG="${srcKubeconfig}" oc create namespace "${probeNs}" \
        --dry-run=client -o yaml --save-config | KUBECONFIG="${srcKubeconfig}" oc apply -f - 1>/dev/null

    # bash ships in ubi9-minimal; no extra package install needed.
    KUBECONFIG="${srcKubeconfig}" oc run "${probePod}" \
        -n "${probeNs}" \
        --rm -i --restart=Never \
        --image=registry.redhat.io/ubi9/ubi-minimal:latest \
        --command -- \
        timeout "${SUBMARINER_CCLM_SYNC_PROBE_TIMEOUT}" bash -c "echo >/dev/tcp/${destIp}/${SUBMARINER_CCLM_SYNC_PORT}" \
        1>/dev/null

    KUBECONFIG="${srcKubeconfig}" oc delete namespace "${probeNs}" \
        --ignore-not-found --wait=false 1>/dev/null &
    true
}

# ── VerifyCclmSyncPath — bidirectional sync-controller TCP reachability ───────
VerifyCclmSyncPath() {
    typeset kcSource="${1:?}"; (($#)) && shift
    typeset kcTarget="${1:?}"; (($#)) && shift
    typeset srcName="${1:?}"; (($#)) && shift
    typeset tgtName="${1:?}"; (($#)) && shift

    typeset srcSyncIp tgtSyncIp

    [[ "${SUBMARINER_VERIFY_CCLM_SYNC}" == "true" ]] || return 0

    srcSyncIp="$(GetSyncControllerPodIp "${kcSource}")"
    tgtSyncIp="$(GetSyncControllerPodIp "${kcTarget}")"

    [[ -n "${srcSyncIp}" ]] || {
        : "No Running virt-synchronization-controller pod IP on '${srcName}'"
        false
    }
    [[ -n "${tgtSyncIp}" ]] || {
        : "No Running virt-synchronization-controller pod IP on '${tgtName}'"
        false
    }

    : "CCLM sync probe ${srcName} -> ${tgtName} (${tgtSyncIp}:${SUBMARINER_CCLM_SYNC_PORT})"
    ProbeCclmSyncPort "${kcSource}" "${tgtSyncIp}" "${srcName}-to-${tgtName}"

    : "CCLM sync probe ${tgtName} -> ${srcName} (${srcSyncIp}:${SUBMARINER_CCLM_SYNC_PORT})"
    ProbeCclmSyncPort "${kcTarget}" "${srcSyncIp}" "${tgtName}-to-${srcName}"

    true
}

# ── VerifyConnectivity — run subctl verify between two spokes ─────────────────
VerifyConnectivity() {
    typeset kc1="${1:?}"; (($#)) && shift
    typeset kc2="${1:?}"; (($#)) && shift
    typeset name1="${1:?}"; (($#)) && shift
    typeset name2="${1:?}"; (($#)) && shift

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
command -v curl 1>/dev/null

LoadSpokeConfig
InstallSubctl

typeset -i submarinerStepRc=0
(
    typeset -i i j
    for ((i = 0; i < spokeCount; i++)); do
        ShowConnections "${spokeKubeconfigsArr[i]}"
    done

    WaitForConnectionsEstablished 600

    for ((i = 0; i < spokeCount; i++)); do
        AssertNoGlobalnetSubnets \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}"
    done

    for ((i = 0; i < spokeCount; i++)); do
        for ((j = i + 1; j < spokeCount; j++)); do
            WarmUpServiceDiscovery \
                "${spokeKubeconfigsArr[i]}" \
                "${spokeKubeconfigsArr[j]}" \
                "${spokeNamesArr[i]}" \
                "${spokeNamesArr[j]}"
        done
    done

    for ((i = 0; i < spokeCount; i++)); do
        for ((j = i + 1; j < spokeCount; j++)); do
            VerifyConnectivity \
                "${spokeKubeconfigsArr[i]}" \
                "${spokeKubeconfigsArr[j]}" \
                "${spokeNamesArr[i]}" \
                "${spokeNamesArr[j]}"
            VerifyCclmSyncPath \
                "${spokeKubeconfigsArr[i]}" \
                "${spokeKubeconfigsArr[j]}" \
                "${spokeNamesArr[i]}" \
                "${spokeNamesArr[j]}"
        done
    done

    : "Final connection status after verify"
    for ((i = 0; i < spokeCount; i++)); do
        ShowConnections "${spokeKubeconfigsArr[i]}"
    done
    true
) || submarinerStepRc=$?

if (( submarinerStepRc != 0 )); then
    : "acm-interop-p2p-submariner-verify failed (rc=${submarinerStepRc})"
    [[ "${SUBMARINER_VERIFY_DEBUG_MODE}" == "true" ]] || exit "${submarinerStepRc}"
    : "SUBMARINER_VERIFY_DEBUG_MODE=true — not failing job"
fi
true
