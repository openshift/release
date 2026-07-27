#!/bin/bash
#
# Install Submariner on all clusters (ACM hub + spokes) via ACM ManagedClusterAddon
# and SubmarinerConfig CRs. Replaces the subctl cloud-prepare + broker-join approach.
#
# ACM's Submariner addon controller handles automatically:
#   - Cloud preparation (AWS security groups, dedicated gateway MachineSet)
#   - Submariner broker deployment on the hub
#   - Cluster join for each enrolled cluster
#   - submariner-operator, gateway, routeagent, lighthouse-agent, coredns install
#
# CRITICAL PREREQUISITE — shared ClusterSet:
#   The ACM Submariner addon creates ONE broker per ManagedClusterSet. Hub and all
#   spokes MUST be in the SAME ClusterSet so they share a single broker. If they are in
#   different ClusterSets the SubmarinerBrokerController sets up separate broker namespaces
#   and the SubmarinerAgentController emits 'BrokerConfigMissing' indefinitely for each
#   cluster because the Submariner broker CR (brokers.submariner.io/submariner-broker)
#   never appears (the hub addon agent cannot create it in the cross-ClusterSet context).
#
#   Phase 0 of this script reads the hub's ClusterSet label and moves every spoke into
#   that same ClusterSet before applying any addon resources.
#
# BROKER CR TIMING:
#   The hub's local submariner-addon agent (deployment/submariner-addon in
#   submariner-operator ns on hub) creates the brokers.submariner.io/submariner-broker CR
#   AFTER: (a) ManagedClusterAddon is applied, (b) ACM provisions the hub's SA+RB in the
#   broker namespace, and (c) the addon agent receives its SA token. This takes 5–20 min.
#   Phase 2.5 waits for this CR before checking for deployment/submariner-operator, which
#   is only created after SubmarinerAgentController reads the broker and dispatches the
#   OLM Subscription ManifestWork.
#
# The hub cluster (local-cluster ManagedCluster, default ClusterSet) is ALSO enrolled
# so that hub↔spoke pod-to-pod connectivity works for CCLM. The subctl-based
# broker-join step only joined spokes; this step closes that gap by also enrolling
# the hub as a Submariner cluster participant.
#
# Globalnet is explicitly disabled (SubmarinerConfig.spec.globalnetEnabled=false).
# Spokes must have non-overlapping pod CIDRs (acm-interop-p2p-cluster-install
# ResolveSpokeCidrs) so cross-cluster raw pod IP routing works for CCLM sync (port 9185).
#
# AWS credentials are read from CLUSTER_PROFILE_DIR and written to a Secret in each
# managed cluster namespace on the hub. Credential writes are wrapped in set +x.
# Secrets are never written to SHARED_DIR.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"
typeset -i addonWaitSeconds=$(( SUBMARINER_ADDON_WAIT_TIMEOUT_MINUTES * 60 ))

typeset -a clusterNamesArr=()    # Parallel: index 0 = hub (local-cluster), 1..N = spokes
typeset -a clusterNsArr=()       # Namespace on hub for each cluster's ACM resources
typeset    hubClusterSet=""      # Set by DetermineHubClusterSet
typeset    submarinerBrokerNs="" # Set by DetermineHubClusterSet: "${hubClusterSet}-broker"

# DumpDiagnostics — write addon and submariner resources to ARTIFACT_DIR on failure.
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/submariner-addon"
    mkdir -p "${diagDir}"

    oc get managedclusteraddon --all-namespaces -o wide \
        > "${diagDir}/managed-cluster-addons.txt" 2>&1 || true
    oc get submarinerconfig --all-namespaces -o wide \
        > "${diagDir}/submariner-configs.txt" 2>&1 || true
    oc get managedcluster -o wide \
        > "${diagDir}/managed-clusters.txt" 2>&1 || true
    oc get managedclusterset \
        > "${diagDir}/managed-cluster-sets.txt" 2>&1 || true

    # Broker CR diagnostics — key indicator of addon health.
    if [[ -n "${submarinerBrokerNs}" ]]; then
        oc get brokers.submariner.io --all-namespaces -o wide \
            > "${diagDir}/submariner-brokers.txt" 2>&1 || true
        oc get all -n "${submarinerBrokerNs}" \
            > "${diagDir}/broker-namespace-resources.txt" 2>&1 || true
    fi

    typeset -i i
    for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
        typeset ns="${clusterNsArr[i]}"
        typeset clusterName="${clusterNamesArr[i]}"
        oc describe managedclusteraddon/submariner -n "${ns}" \
            > "${diagDir}/addon-describe-${clusterName}.txt" 2>&1 || true
        oc describe submarinerconfig/submariner -n "${ns}" \
            > "${diagDir}/submariner-config-describe-${clusterName}.txt" 2>&1 || true
    done
    true
}

# LoadClusterList — populate clusterNamesArr and clusterNsArr.
# Hub (local-cluster) is always index 0; spokes follow.
LoadClusterList() {
    clusterNamesArr=("local-cluster")
    clusterNsArr=("local-cluster")

    typeset -i i
    if (( spokeCount == 1 )); then
        [[ -f "${SHARED_DIR}/managed-cluster-name" ]]
        typeset spkName
        spkName="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")"
        [[ -n "${spkName}" ]]
        clusterNamesArr+=("${spkName}")
        clusterNsArr+=("${spkName}")
    else
        for ((i = 1; i <= spokeCount; i++)); do
            [[ -f "${SHARED_DIR}/managed-cluster-name-${i}" ]]
            typeset spkName
            spkName="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name-${i}")"
            [[ -n "${spkName}" ]]
            clusterNamesArr+=("${spkName}")
            clusterNsArr+=("${spkName}")
        done
    fi
}

# DetermineHubClusterSet — read hub's ClusterSet label and derive the broker namespace.
# Sets globals: hubClusterSet and submarinerBrokerNs.
DetermineHubClusterSet() {
    hubClusterSet="$(oc get managedcluster local-cluster \
        -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}' \
        2>/dev/null || true)"
    [[ -n "${hubClusterSet}" ]] || {
        : "WARN: local-cluster has no clusterset label — defaulting to 'default'" >&2
        hubClusterSet="default"
    }
    submarinerBrokerNs="${hubClusterSet}-broker"
    : "Hub ClusterSet='${hubClusterSet}' — Submariner broker namespace='${submarinerBrokerNs}'"
}

# EnsureSpokesInHubClusterSet — move every spoke into the hub's ClusterSet.
#
# ACM's SubmarinerBrokerController creates ONE broker per ManagedClusterSet. If hub and
# spokes are in different ClusterSets, SubmarinerAgentController looks for a broker in
# separate namespaces (default-broker vs <spoke>-set-broker) and never finds one because
# each cluster's hub addon agent creates the broker only for its own ClusterSet. Moving
# all spokes to the hub's ClusterSet guarantees one shared broker and is safe: ODF/CNV
# are already installed by the time this step runs and ACM won't uninstall them.
EnsureSpokesInHubClusterSet() {
    typeset -i i
    for ((i = 1; i < ${#clusterNamesArr[@]}; i++)); do
        typeset spokeName="${clusterNamesArr[i]}"
        typeset spokeNs="${clusterNsArr[i]}"

        typeset currentSet
        currentSet="$(oc get managedcluster "${spokeName}" \
            -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}' \
            2>/dev/null || true)"

        if [[ "${currentSet}" == "${hubClusterSet}" ]]; then
            : "Spoke '${spokeName}' already in ClusterSet '${hubClusterSet}' — skipping"
        else
            : "Moving spoke '${spokeName}' from ClusterSet '${currentSet:-<none>}' to '${hubClusterSet}'"
            oc label managedcluster "${spokeName}" \
                "cluster.open-cluster-management.io/clusterset=${hubClusterSet}" \
                --overwrite 1>/dev/null
            : "Spoke '${spokeName}' label updated to ClusterSet '${hubClusterSet}'"
        fi

        # Ensure the spoke's hub namespace is bound to the shared ClusterSet so that
        # placement and addon resources in that namespace can reference the ClusterSet.
        oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${hubClusterSet}
  namespace: ${spokeNs}
spec:
  clusterSet: ${hubClusterSet}
EOF
        : "ManagedClusterSetBinding '${hubClusterSet}' ensured in namespace '${spokeNs}'"
    done
}

# WaitForSubmarinerBroker — wait for brokers.submariner.io/submariner-broker to appear.
#
# The hub cluster's submariner-addon agent creates this CR after:
#   1. ManagedClusterAddon/submariner is applied for local-cluster.
#   2. SubmarinerAgentController provisions the hub's ServiceAccount+RoleBinding in the
#      broker namespace.
#   3. The addon registration controller delivers the SA token to the hub agent.
# Until this CR exists, SubmarinerAgentController emits 'BrokerConfigMissing' and will
# NOT create the ManifestWork that triggers OLM to install deployment/submariner-operator.
WaitForSubmarinerBroker() {
    : "Waiting for brokers.submariner.io/submariner-broker in '${submarinerBrokerNs}' (timeout=1800s)"
    (
        typeset -i wInt=20
        SECONDS=0
        until oc get brokers.submariner.io/submariner-broker \
                -n "${submarinerBrokerNs}" 1>/dev/null 2>&1; do
            (( SECONDS < 1800 )) || {
                : "Timeout: brokers.submariner.io/submariner-broker not created in '${submarinerBrokerNs}' within 1800s" >&2
                oc get brokers.submariner.io --all-namespaces -o wide 2>&1 || true
                oc get managedclusteraddon --all-namespaces -o wide 2>&1 || true
                exit 1
            }
            : "Broker CR not yet present (${SECONDS}s elapsed) — retrying in ${wInt}s"
            sleep "${wInt}"
        done
    )
    : "brokers.submariner.io/submariner-broker found in '${submarinerBrokerNs}' — SubmarinerAgentController can now proceed"
}

# EnsureAwsCredsSecret — create AWS credentials Secret in a managed cluster namespace.
# Reads from CLUSTER_PROFILE_DIR/.awscred. Wraps credential reads in set +x.
EnsureAwsCredsSecret() {
    typeset ns="${1:?}"
    typeset secretName="${SUBMARINER_AWS_CREDS_SECRET_NAME}"

    typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"
    [[ -f "${awsCredFile}" ]] || {
        : "AWS credentials file not found: ${awsCredFile}" >&2
        return 1
    }

    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x

    typeset awsKeyId awsSecretKey
    awsKeyId="$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")"
    awsSecretKey="$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")"

    [[ -n "${awsKeyId}" && -n "${awsSecretKey}" ]]

    oc -n "${ns}" create secret generic "${secretName}" \
        --from-literal=aws_access_key_id="${awsKeyId}" \
        --from-literal=aws_secret_access_key="${awsSecretKey}" \
        --dry-run=client -o yaml --save-config | oc apply -f - 1>/dev/null

    [[ "${_wasTracing}" == "true" ]] && set -x
    : "AWS credentials secret '${secretName}' applied in namespace '${ns}'"
}

# ApplySubmarinerConfig — create SubmarinerConfig CR with globalnetEnabled=false.
# ACM's submariner addon controller reads this to configure cloud preparation
# (security groups, gateway MachineSet) and broker join settings.
ApplySubmarinerConfig() {
    typeset ns="${1:?}"
    typeset clusterName="${2:?}"

    # TODO: verify SubmarinerConfig API version on target ACM version (2.7+).
    # submarineraddon.open-cluster-management.io/v1alpha1 is standard for ACM 2.6+.
    jq -n \
        --arg ns            "${ns}" \
        --arg credsSecret   "${SUBMARINER_AWS_CREDS_SECRET_NAME}" \
        --arg instanceType  "${SUBMARINER_GATEWAY_INSTANCE_TYPE}" \
        --argjson gateways  "${SUBMARINER_GATEWAY_COUNT}" \
        --argjson ikePort   "${SUBMARINER_IPSEC_IKE_PORT}" \
        --argjson nattPort  "${SUBMARINER_IPSEC_NATT_PORT}" \
        --arg cableDriver   "${SUBMARINER_CABLE_DRIVER}" \
        --arg subChannel    "${SUBMARINER_SUBSCRIPTION_CHANNEL}" \
        --arg subSource     "${SUBMARINER_SUBSCRIPTION_SOURCE}" \
        --arg subSourceNs   "${SUBMARINER_SUBSCRIPTION_SOURCE_NAMESPACE}" \
        '{
            apiVersion: "submarineraddon.open-cluster-management.io/v1alpha1",
            kind: "SubmarinerConfig",
            metadata: {name: "submariner", namespace: $ns},
            spec: {
                credentialsSecret: {name: $credsSecret},
                gatewayConfig: {
                    aws: {instanceType: $instanceType},
                    gateways: $gateways
                },
                globalnetEnabled: false,
                IPSecIKEPort: $ikePort,
                IPSecNATTPort: $nattPort,
                cableDriver: $cableDriver,
                subscriptionConfig: {
                    channel: $subChannel,
                    source: $subSource,
                    sourceNamespace: $subSourceNs
                }
            }
        }' | oc create -f - --dry-run=client -o yaml --save-config | oc apply -f -
    : "SubmarinerConfig applied in namespace '${ns}' (cluster=${clusterName}, globalnetEnabled=false)"
}

# ApplyManagedClusterAddon — create ManagedClusterAddon/submariner in cluster namespace.
# This triggers ACM's addon controller to install Submariner on the cluster.
ApplyManagedClusterAddon() {
    typeset ns="${1:?}"
    typeset clusterName="${2:?}"

    oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: submariner
  namespace: ${ns}
  annotations:
    addon.open-cluster-management.io/disable-automatic-installation: "false"
spec:
  installNamespace: submariner-operator
EOF
    : "ManagedClusterAddOn/submariner applied in namespace '${ns}' (cluster=${clusterName})"
}

# WaitAddonAvailable — poll until ManagedClusterAddon/submariner is Available.
WaitAddonAvailable() {
    typeset ns="${1:?}"
    typeset clusterName="${2:?}"

    : "Waiting for ManagedClusterAddon/submariner Available on ${clusterName} (timeout=${addonWaitSeconds}s)"
    oc wait "managedclusteraddon/submariner" -n "${ns}" \
        --for=condition=Available \
        --timeout="${addonWaitSeconds}s" 1>/dev/null
    : "ManagedClusterAddon/submariner Available on ${clusterName}"
}

# AssertGlobalnetDisabled — verify SubmarinerConfig shows globalnetEnabled=false.
AssertGlobalnetDisabled() {
    typeset ns="${1:?}"
    typeset clusterName="${2:?}"

    typeset globalnetEnabled
    globalnetEnabled="$(oc get submarinerconfig/submariner -n "${ns}" \
        -o jsonpath='{.spec.globalnetEnabled}' || true)"
    if [[ "${globalnetEnabled}" == "true" ]]; then
        : "ERROR: SubmarinerConfig globalnetEnabled=true on '${clusterName}' — incompatible with CCLM" >&2
        false
    fi
    : "Globalnet disabled on '${clusterName}' (globalnetEnabled=${globalnetEnabled:-false})"
}

# ResolveClusterKubeconfig — return kubeconfig path for a cluster by its index in clusterNamesArr.
# Index 0 = hub (local-cluster) → ${KUBECONFIG} set by ci-operator.
# Index 1..N = spoke N → ${SHARED_DIR}/managed-cluster-kubeconfig-N (from acm-fetch-managed-clusters).
ResolveClusterKubeconfig() {
    typeset -i idx="${1:?}"
    if (( idx == 0 )); then
        printf '%s' "${KUBECONFIG}"
        return 0
    fi
    typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${idx}"
    [[ -r "${kcFile}" ]] || {
        : "Spoke kubeconfig not found at ${kcFile} (cluster index ${idx})" >&2
        return 1
    }
    printf '%s' "${kcFile}"
}

# WaitSubmarinerComponentsReady — wait for all Submariner components to be Ready.
#
# This mirrors the old acm-interop-p2p-submariner-broker-join WaitSubmarinerReady function
# which waited for: submariner-operator, submariner-gateway, submariner-routeagent,
# submariner-lighthouse-agent, and submariner-lighthouse-coredns.
#
# Key difference vs. the old approach: subctl join was synchronous — resources existed by
# the time WaitSubmarinerReady was called. With the addon, ManagedClusterAddon Available
# fires when ACM *dispatches* the ManifestWork, not when the ManifestWork has finished
# syncing to the target cluster. The submariner-operator namespace and deployment may not
# yet exist. We therefore poll for the namespace first, then use oc wait --for=create
# before each --for=condition=Available / rollout status check.
WaitSubmarinerComponentsReady() {
    typeset kc="${1:?}"
    typeset clusterName="${2:?}"

    # Poll until the namespace exists — ManifestWork sync is async after addon Available.
    : "Waiting for submariner-operator namespace on '${clusterName}'"
    (
        typeset -i wInt=15
        SECONDS=0
        until oc --kubeconfig="${kc}" get namespace submariner-operator 1>/dev/null 2>&1; do
            (( SECONDS < 600 )) || {
                : "Timeout: submariner-operator namespace not created on '${clusterName}' within 600s" >&2
                exit 1
            }
            sleep "${wInt}"
        done
    )

    # OLM creates this deployment from the Submariner CSV. Must poll for creation
    # (--for=create) because OLM processes the Subscription asynchronously.
    : "Waiting for submariner-operator deployment Available on '${clusterName}'"
    oc --kubeconfig="${kc}" wait --for=create \
        deployment/submariner-operator -n submariner-operator --timeout=10m 1>/dev/null
    oc --kubeconfig="${kc}" wait deployment/submariner-operator \
        -n submariner-operator --for=condition=Available --timeout=10m 1>/dev/null

    # Gateway DaemonSet — only created after cloud-prep provisions the gateway EC2 instance.
    : "Waiting for submariner-gateway DaemonSet on '${clusterName}'"
    oc --kubeconfig="${kc}" wait --for=create \
        daemonset/submariner-gateway -n submariner-operator --timeout=15m 1>/dev/null
    oc --kubeconfig="${kc}" rollout status daemonset/submariner-gateway \
        -n submariner-operator --timeout=15m 1>/dev/null

    # RouteAgent DaemonSet — runs on every node to program pod-CIDR routes through gateway.
    : "Waiting for submariner-routeagent DaemonSet on '${clusterName}'"
    oc --kubeconfig="${kc}" wait --for=create \
        daemonset/submariner-routeagent -n submariner-operator --timeout=15m 1>/dev/null
    oc --kubeconfig="${kc}" rollout status daemonset/submariner-routeagent \
        -n submariner-operator --timeout=20m 1>/dev/null

    # Lighthouse agent and CoreDNS — required for .clusterset.local service discovery.
    : "Waiting for submariner-lighthouse-agent deployment on '${clusterName}'"
    oc --kubeconfig="${kc}" wait --for=create \
        deployment/submariner-lighthouse-agent -n submariner-operator --timeout=10m 1>/dev/null
    oc --kubeconfig="${kc}" rollout status deployment/submariner-lighthouse-agent \
        -n submariner-operator --timeout=10m 1>/dev/null

    : "Waiting for submariner-lighthouse-coredns deployment on '${clusterName}'"
    oc --kubeconfig="${kc}" wait --for=create \
        deployment/submariner-lighthouse-coredns -n submariner-operator --timeout=10m 1>/dev/null
    oc --kubeconfig="${kc}" rollout status deployment/submariner-lighthouse-coredns \
        -n submariner-operator --timeout=10m 1>/dev/null

    : "All Submariner components ready on '${clusterName}'"
}

# --- Main ---

trap DumpDiagnostics ERR

LoadClusterList

: "Enrolling ${#clusterNamesArr[@]} clusters in Submariner mesh: ${clusterNamesArr[*]}"

# Wait for the ManagedClusterAddon CRD to be Established before Phase 0.
# The MCE addon manager registers managedclusteraddons.addon.open-cluster-management.io
# asynchronously after the MultiClusterHub becomes Available.  If we call
# `oc create --dry-run=client -o yaml` while the CRD is still being created, oc's
# API discovery cache has no mapping for the kind and the command fails immediately
# with "no matches for kind ManagedClusterAddOn" — even though the SubmarinerConfig CRD
# (registered by a separate Submariner controller) is already available.
: "Waiting for managedclusteraddons.addon.open-cluster-management.io CRD to be Established..."
oc wait --for=condition=Established \
    crd/managedclusteraddons.addon.open-cluster-management.io \
    --timeout=300s 1>/dev/null
: "ManagedClusterAddon CRD is Established"

# Phase 0: align all clusters to the hub's ManagedClusterSet.
# ACM Submariner addon creates ONE broker per ClusterSet; all participating clusters
# MUST be in the same ClusterSet or the SubmarinerAgentController loops indefinitely on
# 'BrokerConfigMissing' and never dispatches the ManifestWork that installs submariner-operator.
DetermineHubClusterSet
EnsureSpokesInHubClusterSet

# Phase 1: apply credentials, SubmarinerConfig, and ManagedClusterAddon for all clusters.
typeset -i i
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    typeset clusterName="${clusterNamesArr[i]}"
    typeset ns="${clusterNsArr[i]}"

    : "Configuring Submariner addon for cluster '${clusterName}' (namespace=${ns})"
    EnsureAwsCredsSecret "${ns}"
    ApplySubmarinerConfig "${ns}" "${clusterName}"
    ApplyManagedClusterAddon "${ns}" "${clusterName}"
done

# Phase 2: wait for ManagedClusterAddon/submariner Available on all clusters.
# Sequential to give clear per-cluster status in CI logs.
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    WaitAddonAvailable "${clusterNsArr[i]}" "${clusterNamesArr[i]}"
done

# Phase 2.5: wait for the Submariner broker CR.
# The hub addon agent (deployment/submariner-addon in submariner-operator ns on hub) creates
# brokers.submariner.io/submariner-broker in the broker namespace after its addon
# registration completes and it receives its SA token.  SubmarinerAgentController is
# blocked until this CR appears — it cannot dispatch the OLM Subscription ManifestWork
# that installs deployment/submariner-operator on each cluster until the broker exists.
WaitForSubmarinerBroker

# Phase 2b: wait for actual Submariner data-plane components on all clusters.
# ManagedClusterAddon Available only confirms ACM dispatched the addon manifests. The
# gateway MachineSet must still provision an EC2 instance and submariner-gateway /
# submariner-routeagent DaemonSets must roll out before the IPsec tunnel can establish.
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    typeset clusterKc
    clusterKc="$(ResolveClusterKubeconfig "${i}")"
    WaitSubmarinerComponentsReady "${clusterKc}" "${clusterNamesArr[i]}"
done

# Phase 3: assert Globalnet is disabled on all clusters.
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    AssertGlobalnetDisabled "${clusterNsArr[i]}" "${clusterNamesArr[i]}"
done

if [[ -n "${ARTIFACT_DIR}" ]]; then
    mkdir -p "${ARTIFACT_DIR}/submariner-addon"
    oc get managedclusteraddon --all-namespaces -o wide \
        > "${ARTIFACT_DIR}/submariner-addon/managed-cluster-addons.txt" || true
    oc get submarinerconfig --all-namespaces -o wide \
        > "${ARTIFACT_DIR}/submariner-addon/submariner-configs.txt" || true
fi

: "Submariner addon installed via ACM on: ${clusterNamesArr[*]}"
: "Hub (local-cluster) is enrolled — hub↔spoke pod connectivity available for CCLM"
true
