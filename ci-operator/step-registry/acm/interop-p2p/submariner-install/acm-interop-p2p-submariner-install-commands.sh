#!/bin/bash
#
# Submariner Install & Configure Script
#
# Installs and configures Submariner for a 1-hub + 2-spoke cluster topology
# using the subctl CLI and Globalnet (supports overlapping CIDRs).
#
# Reference: https://submariner.io/getting-started/quickstart/openshift/globalnet/
#
# Flow:
#   1. Install tooling: subctl (via https://get.submariner.io), yq
#   2. Prepare AWS security groups on each spoke (subctl cloud prepare aws)
#   3. Deploy the Submariner broker on the hub cluster (subctl deploy-broker --globalnet)
#   4. Join each spoke to the broker (subctl join)
#   5. Wait for Submariner gateways to become active on both spokes
#   6. Verify spoke-to-spoke connectivity with subctl verify
#   7. Verify service discovery: deploy nginx on spoke-2, access it from spoke-1
#      via nginx.default.svc.clusterset.local (mirrors the manual verification
#      steps in the Submariner Globalnet quickstart guide)
#
# Required files in SHARED_DIR (written by acm-interop-p2p-cluster-install):
#   managed-cluster-name-1         : Spoke 1 cluster name
#   managed-cluster-name-2         : Spoke 2 cluster name
#   managed-cluster-kubeconfig-1   : Spoke 1 kubeconfig
#   managed-cluster-kubeconfig-2   : Spoke 2 kubeconfig
#   managed-cluster-metadata-1.json: Spoke 1 Hive metadata (infraID and aws.region)
#   managed-cluster-metadata-2.json: Spoke 2 Hive metadata
#
# Environment Variables (from ref.yaml):
#   SUBMARINER_GLOBALNET        : enable Globalnet (default: true)
#   SUBMARINER_CABLE_DRIVER     : cable driver (default: libreswan)
#   SUBMARINER_BROKER_NAMESPACE : namespace on hub (default: submariner-k8s-broker)
#   SUBMARINER_VERIFY_TIMEOUT   : subctl verify --connection-timeout seconds (default: 300)
#

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Script-level variables
#=====================
typeset subctlBin="/tmp/subctl"
typeset yqBin="/tmp/yq"
typeset brokerInfoFile="/tmp/broker-info.subm"

# Number of spoke clusters — fixed at 2 for this step
typeset -i spokeCount=2

# Spoke index arrays populated in LoadSpokeConfig
typeset -a spokeNames=()
typeset -a spokeKubeconfigs=()
typeset -a spokeMetadataFiles=()

#=====================
# Need
#   Verifies a command is available; exits with error if not.
# Arguments:
#   $1 - command name
#=====================
Need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] Required command '$1' not found" >&2
        exit 1
    }
    true
}

#=====================
# InstallSubctl
#   Installs subctl via the official Submariner install script
#   (https://get.submariner.io). The script places the binary under
#   ~/.local/bin, which is then added to PATH.
#=====================
InstallSubctl() {
    if command -v subctl >/dev/null 2>&1; then
        echo "[INFO] subctl already on PATH: $(subctl version 2>/dev/null || true)"
        subctlBin="$(command -v subctl)"
        true
        return
    fi

    echo "[INFO] Installing subctl via https://get.submariner.io"
    curl -Ls https://get.submariner.io | bash
    export PATH="${PATH}:${HOME}/.local/bin"
    echo "export PATH=\$PATH:${HOME}/.local/bin" >> "${HOME}/.profile"

    if ! command -v subctl >/dev/null 2>&1; then
        echo "[FATAL] subctl not found on PATH after installation" >&2
        exit 1
    fi
    subctlBin="$(command -v subctl)"
    echo "[INFO] subctl installed: $(subctl version 2>/dev/null || true)"
    true
}

#=====================
# InstallYq
#   Downloads the latest yq binary from GitHub releases if not already present
#   on PATH. yq is used to rename kubeconfig context names before subctl verify.
#=====================
InstallYq() {
    if command -v yq >/dev/null 2>&1; then
        echo "[INFO] yq already on PATH: $(yq --version)"
        yqBin="$(command -v yq)"
        true
        return
    fi

    typeset version
    version="$(
        curl -fsSL \
            "https://api.github.com/repos/mikefarah/yq/releases/latest" |
            jq -r '.tag_name'
    )"
    echo "[INFO] Downloading yq ${version}"

    curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${version}/yq_linux_amd64" \
        -o "${yqBin}"
    chmod +x "${yqBin}"
    export PATH="/tmp:${PATH}"
    echo "[INFO] yq installed: $(yq --version)"
    true
}

#=====================
# SetAwsCredentials
#   Exports AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from the cluster
#   profile credential file, then writes credentials to three locations so that
#   subctl's AWS Go SDK finds them regardless of which lookup path it uses:
#
#   1. env vars (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)
#      — covers SDK implementations that check env vars first.
#   2. AWS_SHARED_CREDENTIALS_FILE → temp file with [default] profile
#      — covers SDK credential-file lookups that honour the override env var.
#   3. ~/.aws/credentials + ~/.aws/config with [default] profile
#      — covers config.WithSharedConfigProfile("default") calls (AWS Go SDK v2)
#        which look for the profile in the shared *config* file (~/.aws/config),
#        NOT in the credentials file. Without ~/.aws/config the SDK throws:
#          "failed to load AWS configuration: failed to get shared config profile, default"
#        even when AWS_SHARED_CREDENTIALS_FILE is correctly set.
#        This was the exact failure observed in rehearse-74415 build-log.txt.
#
#   Tracing is disabled during extraction to prevent credential leakage into CI logs.
#=====================
SetAwsCredentials() {
    echo "[INFO] Loading AWS credentials from cluster profile"

    [[ $- == *x* ]] && typeset wasTracing=true || typeset wasTracing=false
    set +x

    AWS_ACCESS_KEY_ID="$(
        sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' \
            "${CLUSTER_PROFILE_DIR}/.awscred"
    )"
    AWS_SECRET_ACCESS_KEY="$(
        sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' \
            "${CLUSTER_PROFILE_DIR}/.awscred"
    )"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

    # Build the INI block once; reuse it for all three destinations.
    typeset credBlock
    credBlock="$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' \
        "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}")"

    # 2. AWS_SHARED_CREDENTIALS_FILE — overrides the default credentials file path.
    typeset awsTmpCreds
    awsTmpCreds="$(mktemp)"
    printf '%s\n' "${credBlock}" > "${awsTmpCreds}"
    export AWS_SHARED_CREDENTIALS_FILE="${awsTmpCreds}"

    # 3a. ~/.aws/credentials — standard fallback location for the credentials file.
    # 3b. ~/.aws/config     — required by config.WithSharedConfigProfile("default")
    #     in the AWS Go SDK v2; without this the SDK throws
    #     "failed to get shared config profile, default" even when
    #     AWS_SHARED_CREDENTIALS_FILE is set and the env vars are exported.
    mkdir -p "${HOME}/.aws"
    printf '%s\n' "${credBlock}" > "${HOME}/.aws/credentials"
    # The config file uses [default] (not [profile default]) for the default profile.
    printf '%s\n' "${credBlock}" > "${HOME}/.aws/config"

    ${wasTracing} && set -x
    echo "[INFO] AWS credentials loaded (key ID ends: ...${AWS_ACCESS_KEY_ID: -4})"
    echo "[INFO] AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE}"
    echo "[INFO] ~/.aws/credentials and ~/.aws/config written for subctl AWS Go SDK"
    true
}

#=====================
# LoadSpokeConfig
#   Reads spoke cluster names, kubeconfig paths, and metadata file paths from
#   SHARED_DIR into the script-level arrays. Exits if any required file is missing.
#=====================
LoadSpokeConfig() {
    echo "[INFO] Loading spoke cluster configuration from ${SHARED_DIR}"

    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset metaFile="${SHARED_DIR}/managed-cluster-metadata-${i}.json"

        for f in "${nameFile}" "${kcFile}" "${metaFile}"; do
            if [[ ! -f "${f}" ]]; then
                echo "[ERROR] Required file not found: ${f}" >&2
                exit 1
            fi
        done

        spokeNames+=("$(< "${nameFile}")")
        spokeKubeconfigs+=("${kcFile}")
        spokeMetadataFiles+=("${metaFile}")

        echo "[INFO]   Spoke ${i}: name=${spokeNames[-1]}  kubeconfig=${kcFile}"
    done
    true
}

#=====================
# PrepareAwsCluster
#   Runs 'subctl cloud prepare aws' on a cluster to open the required
#   Submariner UDP ports (4500, 4490, 4800) and TCP port 8080 in the node
#   security groups, and to configure gateway nodes with elastic public IPs.
#
#   Uses --ocp-metadata to pass the OCP installer metadata.json directly to
#   subctl, which extracts infraID and region from it automatically.
#   AWS credentials are read from the AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#   environment variables exported by SetAwsCredentials.
#
# Reference: https://submariner.io/getting-started/quickstart/openshift/globalnet/
#
# Arguments:
#   $1 - kubeconfig file path
#   $2 - OCP installer metadata.json file (contains infraID and aws.region)
#   $3 - cluster name (for logging)
#=====================
PrepareAwsCluster() {
    typeset kc="$1"
    typeset metaFile="$2"
    typeset clusterName="$3"

    echo "[INFO] Preparing AWS cluster '${clusterName}' for Submariner"
    echo "[INFO]   kubeconfig : ${kc}"
    echo "[INFO]   ocp-metadata: ${metaFile}"

    "${subctlBin}" cloud prepare aws \
        --kubeconfig "${kc}" \
        --ocp-metadata "${metaFile}"

    echo "[INFO] AWS preparation complete for '${clusterName}'"
    true
}

#=====================
# DeployBroker
#   Deploys the Submariner broker on the hub cluster.
#   Globalnet is enabled by default to handle overlapping CIDRs between spokes.
#   Outputs broker-info.subm to /tmp for use by JoinCluster.
#=====================
DeployBroker() {
    echo "[INFO] Deploying Submariner broker on hub cluster"

    typeset globalnetFlag=""
    if [[ "${SUBMARINER_GLOBALNET:-true}" == "true" ]]; then
        globalnetFlag="--globalnet"
        echo "[INFO] Globalnet enabled (overlapping CIDR support)"
    fi

    # Run in a subshell with cwd=/tmp so broker-info.subm lands in /tmp.
    # --output-dir was removed in recent subctl releases; the file is always
    # written to the current working directory.
    # shellcheck disable=SC2086
    ( cd /tmp && "${subctlBin}" deploy-broker \
        --kubeconfig "${KUBECONFIG}" \
        --namespace "${SUBMARINER_BROKER_NAMESPACE:-submariner-k8s-broker}" \
        ${globalnetFlag} )

    if [[ ! -f "${brokerInfoFile}" ]]; then
        echo "[ERROR] broker-info.subm not found after deploy-broker at ${brokerInfoFile}" >&2
        exit 1
    fi

    echo "[INFO] Broker deployed successfully. Broker info: ${brokerInfoFile}"
    true
}

#=====================
# LabelGatewayNode
#   Labels one worker node on a spoke cluster with submariner.io/gateway=true.
#
#   subctl join interactively prompts "Which node should be used as the gateway?"
#   when no node carries that label. In a non-interactive CI pod, stdin returns
#   EOF immediately, causing the failure:
#     ✗ Error getting gateway node: EOF
#   Pre-labeling a node before calling subctl join suppresses the prompt entirely.
#
# Arguments:
#   $1 - spoke kubeconfig file path
#   $2 - spoke cluster name (for logging)
#=====================
LabelGatewayNode() {
    typeset kc="$1"
    typeset clusterName="$2"

    echo "[INFO] Pre-labeling a gateway node on '${clusterName}'"

    typeset gatewayNode
    gatewayNode="$(
        KUBECONFIG="${kc}" oc get nodes \
            --selector='node-role.kubernetes.io/worker' \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
    )"

    if [[ -z "${gatewayNode}" ]]; then
        echo "[ERROR] No worker node found to label as gateway on '${clusterName}'" >&2
        KUBECONFIG="${kc}" oc get nodes -o wide >&2 || true
        exit 1
    fi

    echo "[INFO] Labeling '${gatewayNode}' as Submariner gateway on '${clusterName}'"
    KUBECONFIG="${kc}" oc label node "${gatewayNode}" submariner.io/gateway=true --overwrite
    echo "[INFO] Gateway node labeled successfully: ${gatewayNode}"
    true
}

#=====================
# JoinCluster
#   Joins a spoke cluster to the Submariner broker.
#   Requires that LabelGatewayNode has already been called for this cluster so
#   that subctl join does not prompt interactively for the gateway node selection.
#
# Arguments:
#   $1 - spoke kubeconfig file path
#   $2 - spoke cluster name (used as clusterID in Submariner)
#=====================
JoinCluster() {
    typeset kc="$1"
    typeset clusterName="$2"

    echo "[INFO] Joining cluster '${clusterName}' to Submariner broker"

    # Argument order matches the docs:
    # subctl join --kubeconfig <kc> broker-info.subm --clusterid <name>
    # NAT traversal is intentionally left at its default (enabled) since
    # both spoke clusters reside in separate AWS VPCs and require NATT for
    # cross-VPC tunnel establishment.
    "${subctlBin}" join \
        --kubeconfig "${kc}" \
        "${brokerInfoFile}" \
        --clusterid "${clusterName}" \
        --cable-driver "${SUBMARINER_CABLE_DRIVER:-libreswan}"

    echo "[INFO] Cluster '${clusterName}' joined broker successfully"
    true
}

#=====================
# WaitSubmarinerReady
#   Polls until the Submariner gateway on a cluster reports 'active' haStatus,
#   or exits with an error after a 30-minute timeout.
#
#   Key implementation notes:
#
#   1. TIMEOUT: 1800s (30 min) instead of 600s.
#      c5n.metal bare-metal nodes have longer image-pull and pod-scheduling
#      times than VM-based workers. The previous 10-minute window was too
#      short; the gateway engine pod never started before the timeout fired,
#      producing 'items: []' for the full poll period (observed in build
#      rehearse-74415 / run 2049098477048172544).
#
#   2. RESOURCE: 'gateways.submariner.io' (fully qualified) instead of 'gateway'.
#      If Gateway API (gateways.gateway.networking.k8s.io) or Istio
#      (gateways.networking.istio.io) is installed, the unqualified short name
#      'gateway' can resolve to the wrong CRD and silently return empty items
#      even when Submariner Gateway CRs exist.
#
#   3. DIAGNOSTICS: on timeout, dump DaemonSet status, pod status, and recent
#      pod events in addition to the Gateway list. These are the fields that
#      reveal whether the pod is Pending (scheduling), ImagePullBackOff (registry),
#      or CrashLoopBackOff (runtime error) — all invisible from the Gateway CR alone.
#
# Arguments:
#   $1 - spoke kubeconfig file path
#   $2 - spoke cluster name (for logging)
#=====================
WaitSubmarinerReady() {
    typeset kc="$1"
    typeset clusterName="$2"
    typeset -i maxWait=1800
    typeset -i interval=15
    typeset -i elapsed=0

    echo "[INFO] Waiting for Submariner gateway to be active on '${clusterName}' (timeout=${maxWait}s)"

    while true; do
        typeset status
        status="$(
            KUBECONFIG="${kc}" oc get gateways.submariner.io \
                -n submariner-operator \
                -o jsonpath='{.items[0].status.haStatus}' 2>/dev/null || echo ""
        )"

        if [[ "${status}" == "active" ]]; then
            echo "[INFO] Submariner gateway is active on '${clusterName}'"
            break
        fi

        if (( elapsed >= maxWait )); then
            echo "[ERROR] Timed out (${maxWait}s) waiting for Submariner gateway on '${clusterName}' (last status='${status}')" >&2

            echo "[DEBUG] --- gateways.submariner.io (yaml) ---" >&2
            KUBECONFIG="${kc}" oc get gateways.submariner.io -n submariner-operator -o yaml 2>&1 || true

            echo "[DEBUG] --- submariner-operator DaemonSets ---" >&2
            KUBECONFIG="${kc}" oc get daemonset -n submariner-operator -o wide 2>&1 || true

            echo "[DEBUG] --- submariner-operator pods ---" >&2
            KUBECONFIG="${kc}" oc get pods -n submariner-operator -o wide 2>&1 || true

            echo "[DEBUG] --- submariner-gateway pod events ---" >&2
            KUBECONFIG="${kc}" oc get events -n submariner-operator \
                --field-selector reason!=Scheduled \
                --sort-by='.lastTimestamp' 2>&1 | tail -40 || true

            echo "[DEBUG] --- submariner-gateway pod logs (last 50 lines) ---" >&2
            typeset gwPod
            gwPod="$(
                KUBECONFIG="${kc}" oc get pods -n submariner-operator \
                    -l app=submariner-gateway \
                    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
            )"
            if [[ -n "${gwPod}" ]]; then
                KUBECONFIG="${kc}" oc logs "${gwPod}" \
                    -n submariner-operator --tail=50 2>&1 || true
            else
                echo "[DEBUG] No submariner-gateway pod found" >&2
            fi

            exit 1
        fi

        echo "[INFO]   Gateway status='${status}' on '${clusterName}', waiting ${interval}s (${elapsed}/${maxWait}s elapsed)"
        sleep "${interval}"
        (( elapsed += interval ))
    done
    true
}

#=====================
# WaitAllSubmarinerComponentsReady
#   Waits for the three Submariner components that enable Globalnet service
#   discovery to reach their rollout-ready state on a given cluster.
#
#   WHY THIS IS REQUIRED:
#   WaitSubmarinerReady only polls 'gateways.submariner.io' haStatus, which
#   reflects the submariner-gateway DaemonSet (the IPsec tunnel). Three other
#   components start independently and are not captured by that check:
#
#   1. submariner-globalnet (DaemonSet)
#      Watches ServiceImport objects and assigns GlobalIngressIP VIPs so that
#      Lighthouse CoreDNS can return a Globalnet IP (242.x.x.x) for remote
#      services. Without this running, 'dig *.svc.clusterset.local' always
#      returns "" — the exact failure seen in the submriner.logs run.
#
#   2. submariner-lighthouse-agent (Deployment)
#      Propagates ServiceExport/ServiceImport objects through the broker to
#      peer clusters. Without this, the remote cluster never learns about
#      exported services.
#
#   3. submariner-lighthouse-coredns (Deployment)
#      Serves the *.svc.clusterset.local DNS zone. Without this running, all
#      cross-cluster DNS queries silently return NXDOMAIN / empty.
#
#   On c5n.metal bare-metal nodes, image pulls and pod scheduling take
#   significantly longer than on VM-based workers. subctl verify was being
#   launched while these three components were still initialising, causing
#   all service-discovery test cases to fail with 'context deadline exceeded'
#   after exhausting their 300-second connection-timeout.
#
# Arguments:
#   $1 - spoke kubeconfig file path
#   $2 - spoke cluster name (for logging)
#=====================
WaitAllSubmarinerComponentsReady() {
    typeset kc="$1"
    typeset clusterName="$2"

    echo "[INFO] Waiting for all Submariner components on '${clusterName}'"

    # 1. Globalnet controller — must be Running before any ServiceImport gets
    #    a GlobalIngressIP and before service-discovery tests will pass.
    echo "[INFO]   submariner-globalnet DaemonSet"
    KUBECONFIG="${kc}" oc rollout status daemonset/submariner-globalnet \
        -n submariner-operator --timeout=10m || {
        echo "[ERROR] submariner-globalnet DaemonSet not ready on '${clusterName}'" >&2
        KUBECONFIG="${kc}" oc get pods -n submariner-operator -o wide >&2 || true
        KUBECONFIG="${kc}" oc get globalingressips -n submariner-operator -o wide 2>&1 || true
        exit 1
    }

    # 2. Lighthouse agent — propagates ServiceExport/ServiceImport through broker.
    echo "[INFO]   submariner-lighthouse-agent Deployment"
    KUBECONFIG="${kc}" oc rollout status deployment/submariner-lighthouse-agent \
        -n submariner-operator --timeout=5m || {
        echo "[ERROR] submariner-lighthouse-agent not ready on '${clusterName}'" >&2
        KUBECONFIG="${kc}" oc get pods -n submariner-operator -o wide >&2 || true
        exit 1
    }

    # 3. Lighthouse CoreDNS — serves *.svc.clusterset.local DNS zone.
    echo "[INFO]   submariner-lighthouse-coredns Deployment"
    KUBECONFIG="${kc}" oc rollout status deployment/submariner-lighthouse-coredns \
        -n submariner-operator --timeout=5m || {
        echo "[ERROR] submariner-lighthouse-coredns not ready on '${clusterName}'" >&2
        KUBECONFIG="${kc}" oc get pods -n submariner-operator -o wide >&2 || true
        exit 1
    }

    echo "[INFO] All Submariner components ready on '${clusterName}'"
    true
}

#=====================
# WaitGlobalnetHeadlessServiceReady
#   Creates a canary headless service on the source cluster, exports it, and
#   verifies that Lighthouse CoreDNS on the target cluster can resolve the
#   service's Globalnet VIP via the generic DNS format:
#     <service>.<namespace>.svc.clusterset.local
#
#   WHY THIS IS REQUIRED (root cause of run 2049494878454288384 and earlier):
#
#   WaitAllSubmarinerComponentsReady confirms that submariner-globalnet,
#   submariner-lighthouse-agent, and submariner-lighthouse-coredns pods are
#   all Running. But "Running" does NOT mean the end-to-end headless service
#   DNS path is functional.
#
#   Observed pattern across 4+ consecutive runs:
#     - StatefulSet pod DNS (web-0.<cluster-id>.<svc>.<ns>.svc.clusterset.local)
#       PASSES in ~18 seconds — this code path works correctly.
#     - Generic headless service DNS (<svc>.<ns>.svc.clusterset.local) FAILS
#       with 'dig' returning "" for the full 247-300 second timeout for EVERY
#       headless service test case in 'subctl verify'.
#
#   This distinguishes two different code paths in the Lighthouse CoreDNS plugin:
#     1. StatefulSet pod DNS — includes cluster-id in the query, resolved by
#        per-endpoint GlobalIngressIP lookups keyed on pod hostname. WORKS.
#     2. Generic headless service DNS — aggregates ALL remote endpoint
#        GlobalIngressIPs without a cluster-id filter. BROKEN in this config
#        (Submariner v0.23.1 + OVNKubernetes + Globalnet on c5n.metal).
#
#   By running this canary before 'subctl verify', we:
#     (a) Confirm the specific code path is functional before running 31 specs;
#     (b) Capture GlobalIngressIP, ServiceImport, and Lighthouse agent logs
#         immediately if the path is broken — rather than discovering failures
#         only after 4+ minutes per test case;
#     (c) Give the system additional time to fully initialise the
#         GlobalIngressIP → ServiceImport update → Lighthouse DNS pipeline,
#         which is slower on c5n.metal bare-metal nodes.
#
# Arguments:
#   $1 - kubeconfig for the source cluster (headless service deployed here)
#   $2 - kubeconfig for the target cluster (dig runs from here)
#   $3 - source cluster name (for logging)
#   $4 - target cluster name (for logging)
#=====================
WaitGlobalnetHeadlessServiceReady() {
    typeset kcSource="$1"
    typeset kcTarget="$2"
    typeset sourceCluster="$3"
    typeset targetCluster="$4"

    typeset canaryNS="submariner-canary"
    typeset canarySvcName="canary-headless"
    typeset -i maxWait=600   # 10 minutes — generous for bare-metal node image pulls
    typeset -i interval=10
    typeset -i elapsed=0

    echo "[INFO] ============================================================"
    echo "[INFO] Globalnet headless service DNS canary test"
    echo "[INFO]   Deploy headless svc on : ${sourceCluster}"
    echo "[INFO]   Verify DNS resolution on: ${targetCluster}"
    echo "[INFO]   Timeout                : ${maxWait}s"
    echo "[INFO] ============================================================"

    # Create the canary namespace idempotently on both clusters
    for kc in "${kcSource}" "${kcTarget}"; do
        KUBECONFIG="${kc}" oc create namespace "${canaryNS}" \
            --dry-run=client -o yaml | KUBECONFIG="${kc}" oc apply -f -
    done

    # Deploy a headless service (clusterIP: None) backed by a single nginx pod
    echo "[INFO] Creating headless canary service on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" oc -n "${canaryNS}" apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: canary
  template:
    metadata:
      labels:
        app: canary
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:stable-alpine
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: canary-headless
spec:
  clusterIP: None
  selector:
    app: canary
  ports:
  - port: 80
    targetPort: 8080
YAML

    # Wait for the canary pod to be running so that endpoints exist
    echo "[INFO] Waiting for canary deployment to be ready on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" oc -n "${canaryNS}" rollout status \
        deployment/canary --timeout=5m

    # Export the headless service via Submariner so Lighthouse publishes it
    echo "[INFO] Exporting canary headless service on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" "${subctlBin}" export service \
        --namespace "${canaryNS}" "${canarySvcName}"

    # ----------------------------------------------------------------
    # Phase 1: Wait for GlobalIngressIP to be assigned on the SOURCE cluster.
    #
    # For a headless service Globalnet assigns one GlobalIngressIP per backing
    # pod endpoint (as opposed to one per Service for ClusterIP services).
    # The allocated IP is the Globalnet VIP that remote clusters will resolve.
    # Without this, Lighthouse DNS on the target cluster returns "".
    # ----------------------------------------------------------------
    typeset giAllocatedIP=""
    typeset -i giWait=0
    typeset -i giMax=300
    echo "[INFO] Waiting for GlobalIngressIP for '${canarySvcName}' on '${sourceCluster}' (timeout=${giMax}s)"
    while (( giWait < giMax )); do
        giAllocatedIP="$(
            KUBECONFIG="${kcSource}" oc get globalingressips \
                -n "${canaryNS}" \
                -o jsonpath='{.items[0].status.allocatedIP}' 2>/dev/null || true
        )"
        if [[ -n "${giAllocatedIP}" ]]; then
            echo "[INFO] GlobalIngressIP assigned: ${giAllocatedIP} (after ${giWait}s)"
            break
        fi
        echo "[INFO]   No GlobalIngressIP yet on '${sourceCluster}' (${giWait}/${giMax}s)"
        sleep "${interval}"
        (( giWait += interval ))
    done

    if [[ -z "${giAllocatedIP}" ]]; then
        echo "[ERROR] GlobalIngressIP not assigned for '${canarySvcName}' on '${sourceCluster}' after ${giMax}s" >&2
        echo "[DEBUG] All GlobalIngressIPs on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get globalingressips -A -o wide 2>&1 || true
        echo "[DEBUG] ServiceExports on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get serviceexports -A -o wide 2>&1 || true
        echo "[DEBUG] GlobalIngressIP CRD on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get crd globalingressips.submariner.io -o yaml 2>&1 | head -30 || true
        # Capture submariner-globalnet pod logs — most likely to reveal the failure reason
        typeset gnPod
        gnPod="$(
            KUBECONFIG="${kcSource}" oc get pods -n submariner-operator \
                -l app=submariner-globalnet \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
        )"
        if [[ -n "${gnPod}" ]]; then
            echo "[DEBUG] submariner-globalnet pod logs on '${sourceCluster}' (last 80 lines):" >&2
            KUBECONFIG="${kcSource}" oc logs "${gnPod}" \
                -n submariner-operator --tail=80 2>&1 || true
        fi
        exit 1
    fi

    # ----------------------------------------------------------------
    # Phase 2: Verify DNS from the TARGET cluster resolves the Globalnet VIP
    # using the generic headless service format:
    #   <service>.<namespace>.svc.clusterset.local
    #
    # This is the EXACT DNS pattern used by 'subctl verify' headless tests and
    # the one that was consistently returning "" in all previous runs despite
    # GlobalIngressIP assignment succeeding on the source cluster.
    # A successful resolution here proves the full propagation pipeline:
    #   GlobalIngressIP (source) → lighthouse-agent (source) →
    #   broker → lighthouse-agent (target) → lighthouse-coredns (target) → DNS
    # ----------------------------------------------------------------
    echo "[INFO] Creating dig pod on '${targetCluster}'"
    KUBECONFIG="${kcTarget}" oc -n "${canaryNS}" delete pod submariner-canary-dig \
        --ignore-not-found --grace-period=0 2>/dev/null || true
    KUBECONFIG="${kcTarget}" oc -n "${canaryNS}" run submariner-canary-dig \
        --image=quay.io/submariner/nettest \
        --restart=Never \
        --command -- sleep 700
    KUBECONFIG="${kcTarget}" oc -n "${canaryNS}" wait pod/submariner-canary-dig \
        --for=condition=Ready --timeout=3m

    typeset digResult=""
    echo "[INFO] Polling dig on '${targetCluster}': '${canarySvcName}.${canaryNS}.svc.clusterset.local' (timeout=${maxWait}s)"
    while (( elapsed < maxWait )); do
        digResult="$(
            KUBECONFIG="${kcTarget}" oc -n "${canaryNS}" exec \
                submariner-canary-dig -- \
                dig +short "${canarySvcName}.${canaryNS}.svc.clusterset.local" \
                2>/dev/null || true
        )"
        if [[ -n "${digResult}" ]]; then
            echo "[INFO] Headless DNS resolved after ${elapsed}s: '${canarySvcName}' -> '${digResult}'"
            break
        fi
        echo "[INFO]   dig returned '' (${elapsed}/${maxWait}s elapsed)"
        sleep "${interval}"
        (( elapsed += interval ))
    done

    if [[ -z "${digResult}" ]]; then
        echo "[ERROR] Headless service DNS did not resolve on '${targetCluster}' after ${maxWait}s" >&2
        echo "[ERROR]   Expected GlobalIngressIP VIP: ${giAllocatedIP}" >&2
        echo "[DEBUG] ServiceImports on '${targetCluster}':" >&2
        KUBECONFIG="${kcTarget}" oc get serviceimports -A -o wide 2>&1 || true
        echo "[DEBUG] GlobalIngressIPs on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get globalingressips -A -o wide 2>&1 || true
        # Lighthouse agent on SOURCE — responsible for propagating VIP to broker
        typeset laSourcePod
        laSourcePod="$(
            KUBECONFIG="${kcSource}" oc get pods -n submariner-operator \
                -l app=submariner-lighthouse-agent \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
        )"
        if [[ -n "${laSourcePod}" ]]; then
            echo "[DEBUG] submariner-lighthouse-agent logs on '${sourceCluster}' (last 80 lines):" >&2
            KUBECONFIG="${kcSource}" oc logs "${laSourcePod}" \
                -n submariner-operator --tail=80 2>&1 || true
        fi
        # Lighthouse agent on TARGET — responsible for creating local ServiceImport
        typeset laTargetPod
        laTargetPod="$(
            KUBECONFIG="${kcTarget}" oc get pods -n submariner-operator \
                -l app=submariner-lighthouse-agent \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
        )"
        if [[ -n "${laTargetPod}" ]]; then
            echo "[DEBUG] submariner-lighthouse-agent logs on '${targetCluster}' (last 80 lines):" >&2
            KUBECONFIG="${kcTarget}" oc logs "${laTargetPod}" \
                -n submariner-operator --tail=80 2>&1 || true
        fi
        # Lighthouse CoreDNS on TARGET — serves the actual DNS answers
        typeset coreTargetPod
        coreTargetPod="$(
            KUBECONFIG="${kcTarget}" oc get pods -n submariner-operator \
                -l app=submariner-lighthouse-coredns \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
        )"
        if [[ -n "${coreTargetPod}" ]]; then
            echo "[DEBUG] submariner-lighthouse-coredns logs on '${targetCluster}' (last 80 lines):" >&2
            KUBECONFIG="${kcTarget}" oc logs "${coreTargetPod}" \
                -n submariner-operator --tail=80 2>&1 || true
        fi
        exit 1
    fi

    # Cleanup canary resources on both clusters
    echo "[INFO] Cleaning up canary resources"
    KUBECONFIG="${kcSource}" oc delete namespace "${canaryNS}" \
        --ignore-not-found 2>/dev/null || true
    KUBECONFIG="${kcTarget}" oc delete namespace "${canaryNS}" \
        --ignore-not-found 2>/dev/null || true

    echo "[INFO] Globalnet headless service DNS canary test PASSED"
    true
}

#=====================
# VerifyConnectivity
#   Runs 'subctl verify' between two spoke clusters to validate that
#   Submariner tunnels are established and cross-cluster connectivity works.
#
#   Both kubeconfigs are merged via the KUBECONFIG env var (colon-separated).
#   Context names and user entries are rewritten with yq so each clusterID is
#   unique in the merged config — required by subctl verify's --context flags.
#
#   Pattern follows: https://submariner.io/getting-started/quickstart/openshift/globalnet/
#
# Arguments:
#   $1 - kubeconfig for cluster A (spoke-1)
#   $2 - kubeconfig for cluster B (spoke-2)
#   $3 - cluster A name (becomes --context value and clusterID)
#   $4 - cluster B name (becomes --tocontext value and clusterID)
#=====================
VerifyConnectivity() {
    typeset kc1="$1"
    typeset kc2="$2"
    typeset clusterID1="$3"
    typeset clusterID2="$4"

    echo "[INFO] Verifying Submariner connectivity: '${clusterID1}' <-> '${clusterID2}'"

    # Work on copies so the originals are not modified
    typeset kc1Copy="/tmp/kubeconfig-${clusterID1}.yaml"
    typeset kc2Copy="/tmp/kubeconfig-${clusterID2}.yaml"
    cp "${kc1}" "${kc1Copy}"
    cp "${kc2}" "${kc2Copy}"

    # Rename context names and user entries in each copy so they are unique
    # when the two kubeconfigs are merged. Follows the yq pattern from the
    # Submariner Globalnet quickstart docs.
    "${yqBin}" -i \
        ".contexts[0].name = \"${clusterID1}\" | .current-context = \"${clusterID1}\"" \
        "${kc1Copy}"
    "${yqBin}" -i \
        ".contexts[0].context.user = \"admin-${clusterID1}\" | .users[0].name = \"admin-${clusterID1}\"" \
        "${kc1Copy}"

    "${yqBin}" -i \
        ".contexts[0].name = \"${clusterID2}\" | .current-context = \"${clusterID2}\"" \
        "${kc2Copy}"
    "${yqBin}" -i \
        ".contexts[0].context.user = \"admin-${clusterID2}\" | .users[0].name = \"admin-${clusterID2}\"" \
        "${kc2Copy}"

    echo "[INFO] Running subctl verify between '${clusterID1}' and '${clusterID2}'"
    KUBECONFIG="${kc1Copy}:${kc2Copy}" \
        "${subctlBin}" verify \
            --context "${clusterID1}" \
            --tocontext "${clusterID2}" \
            --only service-discovery,connectivity \
            --connection-timeout "${SUBMARINER_VERIFY_TIMEOUT:-300}" \
            --verbose

    echo "[INFO] Connectivity verification passed: '${clusterID1}' <-> '${clusterID2}'"
    true
}

#=====================
# VerifyNginxConnectivity
#   Validates cross-cluster service discovery by deploying an nginx ClusterIP
#   service on the source cluster, exporting it via 'subctl export service',
#   then running a curl from the target cluster using submariner/nettest.
#
#   This mirrors the manual verification steps from the Submariner Globalnet
#   quickstart: https://submariner.io/getting-started/quickstart/openshift/globalnet/
#
#   The exported service is reachable across clusters as:
#     nginx.default.svc.clusterset.local:8080
#
# Arguments:
#   $1 - kubeconfig for the source cluster (nginx is deployed here; spoke-2)
#   $2 - kubeconfig for the target cluster (curl runs from here; spoke-1)
#   $3 - source cluster name (for logging)
#   $4 - target cluster name (for logging)
#=====================
VerifyNginxConnectivity() {
    typeset kcSource="$1"
    typeset kcTarget="$2"
    typeset sourceCluster="$3"
    typeset targetCluster="$4"

    echo "[INFO] =================================================="
    echo "[INFO] Verifying nginx cross-cluster service discovery"
    echo "[INFO]   nginx deployed on : ${sourceCluster}"
    echo "[INFO]   curl runs from    : ${targetCluster}"
    echo "[INFO] =================================================="

    # Deploy nginx on the source cluster (idempotent via dry-run + apply)
    echo "[INFO] Deploying nginx on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" oc -n default create deployment nginx \
        --image=nginxinc/nginx-unprivileged:stable-alpine \
        --dry-run=client -o yaml | KUBECONFIG="${kcSource}" oc apply -f -

    echo "[INFO] Waiting for nginx deployment to be ready on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" oc -n default rollout status deployment/nginx --timeout=5m

    # Expose as ClusterIP on port 8080 (idempotent)
    KUBECONFIG="${kcSource}" oc -n default expose deployment nginx --port=8080 \
        --dry-run=client -o yaml | KUBECONFIG="${kcSource}" oc apply -f -

    # Export the service for cross-cluster discovery via Submariner
    echo "[INFO] Exporting nginx service on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" "${subctlBin}" export service --namespace default nginx

    # Poll until the ServiceImport appears on the target cluster instead of
    # using a blind sleep. The propagation chain is:
    #   ServiceExport (source) → lighthouse-agent → broker → lighthouse-agent
    #   (target) → ServiceImport (target) → globalnet → GlobalIngressIP (target)
    # On c5n.metal nodes this chain can take 60-120 s; a fixed 30 s sleep
    # under-waits and causes the nettest curl to fail before DNS resolves.
    typeset -i siWait=0
    typeset -i siMax=180
    echo "[INFO] Waiting for ServiceImport 'nginx' to appear on '${targetCluster}' (timeout=${siMax}s)"
    while (( siWait < siMax )); do
        if KUBECONFIG="${kcTarget}" oc get serviceimport nginx -n default &>/dev/null 2>&1; then
            echo "[INFO] ServiceImport 'nginx' found on '${targetCluster}' after ${siWait}s"
            break
        fi
        echo "[INFO]   ServiceImport not yet available (${siWait}/${siMax}s elapsed)"
        sleep 10
        (( siWait += 10 ))
    done
    if (( siWait >= siMax )); then
        echo "[ERROR] ServiceImport 'nginx' not found on '${targetCluster}' after ${siMax}s" >&2
        echo "[DEBUG] ServiceImports in default namespace on '${targetCluster}':" >&2
        KUBECONFIG="${kcTarget}" oc get serviceimports -n default -o wide 2>&1 || true
        echo "[DEBUG] GlobalIngressIPs on '${targetCluster}':" >&2
        KUBECONFIG="${kcTarget}" oc get globalingressips -n default -o wide 2>&1 || true
        exit 1
    fi

    # Clean up any previous nettest pod before running
    KUBECONFIG="${kcTarget}" oc -n default delete pod submariner-nettest \
        --ignore-not-found --grace-period=0 2>/dev/null || true

    # Run a curl from the target cluster using the submariner/nettest image.
    # The service is accessible as: nginx.default.svc.clusterset.local:8080
    echo "[INFO] Running nettest curl from '${targetCluster}' -> nginx.default.svc.clusterset.local:8080"
    KUBECONFIG="${kcTarget}" oc -n default run submariner-nettest \
        --image=quay.io/submariner/nettest \
        --restart=Never \
        -- curl -sS --retry 5 --retry-delay 10 --retry-all-errors \
        "nginx.default.svc.clusterset.local:8080"

    # Poll until the nettest pod completes
    typeset -i elapsed=0
    typeset -i maxWait=180
    typeset podPhase=""
    echo "[INFO] Waiting for nettest pod to complete (up to ${maxWait}s)"
    while (( elapsed < maxWait )); do
        podPhase="$(
            KUBECONFIG="${kcTarget}" oc get pod submariner-nettest -n default \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown"
        )"
        if [[ "${podPhase}" == "Succeeded" ]]; then
            break
        elif [[ "${podPhase}" == "Failed" ]]; then
            echo "[ERROR] nettest pod failed on '${targetCluster}'" >&2
            KUBECONFIG="${kcTarget}" oc -n default logs submariner-nettest >&2 || true
            exit 1
        fi
        echo "[INFO]   nettest pod phase='${podPhase}' (${elapsed}/${maxWait}s elapsed)"
        sleep 15
        (( elapsed += 15 ))
    done

    if [[ "${podPhase}" != "Succeeded" ]]; then
        echo "[ERROR] nettest pod did not complete within ${maxWait}s (phase='${podPhase}')" >&2
        KUBECONFIG="${kcTarget}" oc -n default describe pod submariner-nettest >&2 || true
        exit 1
    fi

    typeset response
    response="$(KUBECONFIG="${kcTarget}" oc -n default logs submariner-nettest)"
    echo "[INFO] nginx response (first 300 chars): ${response:0:300}"
    echo "[INFO] Service discovery confirmed: '${targetCluster}' -> nginx on '${sourceCluster}'"

    # Cleanup test resources
    echo "[INFO] Cleaning up nginx test resources"
    KUBECONFIG="${kcTarget}" oc -n default delete pod submariner-nettest --ignore-not-found
    KUBECONFIG="${kcSource}" oc -n default delete svc nginx --ignore-not-found
    KUBECONFIG="${kcSource}" oc -n default delete deployment nginx --ignore-not-found
    true
}

#=====================
# Main
#=====================

Need oc
Need jq
Need curl

LoadSpokeConfig
SetAwsCredentials
InstallSubctl
InstallYq

typeset -i i

# Prepare AWS security groups on each spoke (hub does not need this)
for ((i = 0; i < spokeCount; i++)); do
    PrepareAwsCluster \
        "${spokeKubeconfigs[i]}" \
        "${spokeMetadataFiles[i]}" \
        "${spokeNames[i]}"
done

DeployBroker

# Pre-label one gateway node on each spoke before joining.
# subctl join asks interactively which node to use as the gateway;
# in a non-interactive CI pod stdin is closed (EOF), causing:
#   ✗ Error getting gateway node: EOF
# Labeling the node first suppresses the prompt entirely.
for ((i = 0; i < spokeCount; i++)); do
    LabelGatewayNode "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Join each spoke to the broker
for ((i = 0; i < spokeCount; i++)); do
    JoinCluster "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Wait for gateways to become active on both spokes
for ((i = 0; i < spokeCount; i++)); do
    WaitSubmarinerReady "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Wait for Globalnet, Lighthouse agent, and Lighthouse CoreDNS to be fully
# ready before running subctl verify. The gateway haStatus being 'active'
# only confirms the IPsec tunnel is up — it does NOT guarantee that
# GlobalIngressIPs will be assigned for remote ServiceImports or that
# *.svc.clusterset.local DNS will resolve. Skipping this wait causes all
# service-discovery tests in subctl verify to fail with empty dig results.
for ((i = 0; i < spokeCount; i++)); do
    WaitAllSubmarinerComponentsReady "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Canary: verify that the generic headless service Globalnet DNS path
# (service.namespace.svc.clusterset.local) works end-to-end before running
# the full subctl verify suite (31 test specs, 4+ min each on failure).
#
# WHY this is needed after WaitAllSubmarinerComponentsReady:
#   All Submariner pods pass rollout status, but the headless service DNS code
#   path (Globalnet endpoint → lighthouse-agent propagation → CoreDNS response)
#   was systematically returning "" for 247-300 s per test across 4 consecutive
#   runs. StatefulSet pod DNS (different code path) always passed.
#   The canary either confirms the path works or fails fast with diagnostics from
#   GlobalIngressIP CRs, ServiceImport state, and lighthouse-agent/coredns logs.
for ((i = 0; i < spokeCount - 1; i++)); do
    WaitGlobalnetHeadlessServiceReady \
        "${spokeKubeconfigs[$((i + 1))]}" \
        "${spokeKubeconfigs[i]}" \
        "${spokeNames[$((i + 1))]}" \
        "${spokeNames[i]}"
done

# Capture full Submariner diagnostic state on both clusters before running
# subctl verify. This preserves the cluster health snapshot in CI artifacts
# and is invaluable when individual test cases fail.
for ((i = 0; i < spokeCount; i++)); do
    echo "[INFO] --- subctl diagnose all on '${spokeNames[i]}' ---"
    KUBECONFIG="${spokeKubeconfigs[i]}" "${subctlBin}" diagnose all 2>&1 || true
done

# Step 6: subctl verify — automated tunnel and service-discovery validation
# For 2 spokes this is exactly one pair: spoke-1 <-> spoke-2
for ((i = 0; i < spokeCount - 1; i++)); do
    VerifyConnectivity \
        "${spokeKubeconfigs[i]}" \
        "${spokeKubeconfigs[$((i + 1))]}" \
        "${spokeNames[i]}" \
        "${spokeNames[$((i + 1))]}"
done

# Step 7: nginx service-discovery verification
# Deploy nginx on spoke-2, export the service, curl it from spoke-1.
# Mirrors the manual ClusterIP verification from the Submariner Globalnet docs.
VerifyNginxConnectivity \
    "${spokeKubeconfigs[1]}" \
    "${spokeKubeconfigs[0]}" \
    "${spokeNames[1]}" \
    "${spokeNames[0]}"

echo "[INFO] Submariner installation and connectivity verification complete"
true
