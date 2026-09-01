#!/bin/bash
#
# Upgrades the ACM managed spoke cluster (single spoke from cluster-install).
# Spoke direct: channel patch, admin-ack, klusterlet-work RBAC bootstrap, oc wait.
# Hub ManifestWork: ClusterVersion desiredUpdate.image only.
# Requires acm-fetch-managed-clusters (${SHARED_DIR}/kubeconfig) and
# acm-interop-p2p-cluster-install (${SHARED_DIR}/managed-cluster-kubeconfig,
# ${SHARED_DIR}/managed-cluster-name).
#
# When SPOKE_CLUSTER_UPGRADE_EUS=true, performs a control-plane-only (CPOU)
# multi-hop upgrade using ${SHARED_DIR}/upgrade-edge (written by
# cucushift-upgrade-setedge-2hops): pause worker MCP, hop each image in order,
# unpause worker MCP. Single-hop jobs leave the flag false.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq yq

[ -f "${SHARED_DIR}/kubeconfig" ]
[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
[ -f "${SHARED_DIR}/managed-cluster-name" ]

typeset hubKubeconfig="${SHARED_DIR}/kubeconfig"
typeset spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
typeset spokeName
spokeName="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")"
[[ -n "${spokeName}" ]]

typeset currentHopVersion=''

WriteSpokeUpgradeFailureDiagnostics() {
    typeset artifactFile="${ARTIFACT_DIR}/spoke-${spokeName}-upgrade-failure.txt"
    {
        printf '%s\n' "=== currentHopVersion=${currentHopVersion:-unknown} SPOKE_CLUSTER_UPGRADE_EUS=${SPOKE_CLUSTER_UPGRADE_EUS} ==="
        printf '\n'
        printf '%s\n' "=== oc get clusterversion version ==="
        oc --kubeconfig="${spokeKubeconfig}" get clusterversion version -o wide 2>&1 || true
        printf '\n'
        printf '%s\n' "=== oc describe clusterversion version ==="
        oc --kubeconfig="${spokeKubeconfig}" describe clusterversion version 2>&1 || true
        printf '\n'
        printf '%s\n' "=== oc get machineconfigpools ==="
        oc --kubeconfig="${spokeKubeconfig}" get machineconfigpools -o wide 2>&1 || true
        printf '\n'
        printf '%s\n' "=== oc get nodes ==="
        oc --kubeconfig="${spokeKubeconfig}" get nodes -o wide 2>&1 || true
        printf '\n'
        printf '%s\n' "=== oc get clusteroperators ==="
        oc --kubeconfig="${spokeKubeconfig}" get clusteroperators 2>&1 || true
    } > "${artifactFile}"
    : "Wrote spoke upgrade failure diagnostics to ${artifactFile}"
    true
}

SpokeUpgradeFailureCleanup() {
    typeset -i ret=$?
    if (( ret != 0 )); then
        WriteSpokeUpgradeFailureDiagnostics || true
    fi
    return "${ret}"
}
trap SpokeUpgradeFailureCleanup EXIT

ResolveReleaseImage() {
    typeset pullspec="${1:?}"; (($#)) && shift
    typeset -n _version="${1:?}"; (($#)) && shift
    typeset -n _image="${1:?}"; (($#)) && shift
    typeset releaseInfoJson digest imgRepo
    releaseInfoJson="$(oc adm release info "${pullspec}" -o json)"
    _version="$(jq -r '.metadata.version' <<<"${releaseInfoJson}")"
    digest="$(jq -r '.digest' <<<"${releaseInfoJson}")"
    [[ -n "${_version}" ]]
    [[ -n "${digest}" ]]
    imgRepo="${pullspec%:*}"
    imgRepo="${imgRepo%@sha256*}"
    _image="${imgRepo}@${digest}"
    true
}

PatchAdminAcksForUpgrade() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset upgradeableMsg='' ackKey=''
    upgradeableMsg="$(oc --kubeconfig="${kubeconfig}" get clusterversion version \
        -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].message}' || true)"
    if [[ -n "${upgradeableMsg}" ]]; then
        ackKey="$(grep -oE 'ack-[a-zA-Z0-9.-]+' <<<"${upgradeableMsg}" | head -1 || true)"
    fi
    if [[ -n "${ackKey}" ]]; then
        : "Patching admin-ack '${ackKey}' from Upgradeable condition on spoke"
        oc --kubeconfig="${kubeconfig}" patch configmap admin-acks-upgrades -n openshift-config \
            --type merge \
            -p "$(jq -cn --arg k "${ackKey}" '{data: {($k): "true"}}')" \
            || : "admin-acks-upgrades patch skipped (ConfigMap may not exist on this cluster)"
    else
        : "No admin-ack key in Upgradeable condition; skipping patch"
    fi
    true
}

ApplySpokeClusterVersionRbac() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset manifestFile="${1:?}"; (($#)) && shift
    cat > "${manifestFile}" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: klusterlet-work-clusterversion
rules:
- apiGroups: ["config.openshift.io"]
  resources: ["clusterversions"]
  verbs: ["get", "list", "watch", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: klusterlet-work-clusterversion
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: klusterlet-work-clusterversion
subjects:
- kind: ServiceAccount
  name: klusterlet-work-sa
  namespace: open-cluster-management-agent
EOF
    : "Applying klusterlet-work ClusterVersion RBAC on spoke"
    oc --kubeconfig="${kubeconfig}" apply -f "${manifestFile}"
    true
}

ApplySpokeUpgradeManifestWork() {
    typeset mwNamespace="${1:?}"; (($#)) && shift
    typeset mwName="${1:?}"; (($#)) && shift
    typeset manifestFile="${1:?}"; (($#)) && shift
    typeset pinnedImage="${1:?}"; (($#)) && shift
    cat > "${manifestFile}" <<EOF
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${mwName}
  namespace: ${mwNamespace}
spec:
  deleteOption:
    propagationPolicy: Orphan
  manifestConfigs:
  - resourceIdentifier:
      group: config.openshift.io
      resource: clusterversions
      namespace: ""
      name: version
    updateStrategy:
      type: ServerSideApply
  workload:
    manifests:
    - apiVersion: config.openshift.io/v1
      kind: ClusterVersion
      metadata:
        name: version
      spec:
        desiredUpdate:
          force: true
          image: ${pinnedImage}
EOF
    : "Applying ManifestWork ${mwName} in namespace ${mwNamespace} on hub"
    KUBECONFIG="${hubKubeconfig}" oc apply -f "${manifestFile}"
    true
}

WaitSpokeUpgradeCompleted() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset version="${1:?}"; (($#)) && shift
    : "Waiting for spoke ClusterVersion ${version} to reach Completed (${ACM_SPOKE_UPGRADE_TIMEOUT})"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].version}'="${version}" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].state}'="Completed" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}"
    true
}

WaitMcpCondition() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset mcp="${1:?}"; (($#)) && shift
    typeset condition="${1:?}"; (($#)) && shift
    typeset timeout="${1:?}"; (($#)) && shift
    : "Waiting for spoke mcp/${mcp} condition ${condition} (${timeout})"
    oc --kubeconfig="${kubeconfig}" wait "mcp/${mcp}" \
        --for="condition=${condition}" \
        --timeout="${timeout}"
    true
}

SetWorkerMcpPaused() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset paused="${1:?}"; (($#)) && shift
    typeset actual=''
    : "Setting spoke mcp/worker spec.paused=${paused}"
    oc --kubeconfig="${kubeconfig}" patch mcp/worker --type merge \
        -p "$(jq -cn --argjson p "${paused}" '{"spec":{"paused":$p}}')"
    actual="$(oc --kubeconfig="${kubeconfig}" get mcp/worker -o jsonpath='{.spec.paused}')"
    [[ "${actual}" == "${paused}" ]]
    true
}

DumpSpokeUpgradeStatus() {
    typeset label="${1:?}"; (($#)) && shift
    oc --kubeconfig="${spokeKubeconfig}" get clusterversion version -o wide \
        > "${ARTIFACT_DIR}/spoke-${spokeName}-clusterversion-${label}.txt"
    oc --kubeconfig="${spokeKubeconfig}" get machineconfigpools -o wide \
        > "${ARTIFACT_DIR}/spoke-${spokeName}-mcp-${label}.txt"
    true
}

UpgradeSpokeToPullspec() {
    typeset pullspec="${1:?}"; (($#)) && shift
    typeset hopVersion='' hopImage=''
    ResolveReleaseImage "${pullspec}" hopVersion hopImage
    currentHopVersion="${hopVersion}"
    : "Upgrading spoke ${spokeName} to ${hopVersion}"
    PatchAdminAcksForUpgrade "${spokeKubeconfig}"
    ApplySpokeUpgradeManifestWork "${spokeName}" "${ACM_MANIFESTWORK_NAME}" \
        "${mwManifest}" "${hopImage}"
    WaitSpokeUpgradeCompleted "${spokeKubeconfig}" "${hopVersion}"
    WaitMcpCondition "${spokeKubeconfig}" master Updated "${ACM_SPOKE_UPGRADE_TIMEOUT}"
    DumpSpokeUpgradeStatus "${hopVersion}"
    true
}

typeset -r rbacManifest="${ARTIFACT_DIR}/spoke-${spokeName}-clusterversion-rbac.yaml"
typeset -r mwManifest="${ARTIFACT_DIR}/spoke-${spokeName}-ocp-upgrade-manifestwork.yaml"

: "Upgrading spoke cluster ${spokeName}"

if [[ -n "${SPOKE_CLUSTER_UPGRADE_TARGET_CHANNEL}" ]]; then
    : "Patching spoke ClusterVersion channel to ${SPOKE_CLUSTER_UPGRADE_TARGET_CHANNEL}"
    oc --kubeconfig="${spokeKubeconfig}" patch clusterversion version --type merge \
        -p "$(jq -cn --arg ch "${SPOKE_CLUSTER_UPGRADE_TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"
fi

ApplySpokeClusterVersionRbac "${spokeKubeconfig}" "${rbacManifest}"

if [[ "${SPOKE_CLUSTER_UPGRADE_EUS}" == "true" ]]; then
    typeset hopPullspecs='' hopPullspec=''
    typeset -a hopImages=()
    [ -f "${SHARED_DIR}/upgrade-edge" ]
    hopPullspecs="$(< "${SHARED_DIR}/upgrade-edge")"
    [[ -n "${hopPullspecs}" ]]
    IFS=',' read -r -a hopImages <<< "${hopPullspecs}"
    (( ${#hopImages[@]} >= 2 ))
    : "EUS CPOU spoke upgrade via ${#hopImages[@]} hops from upgrade-edge"
    SetWorkerMcpPaused "${spokeKubeconfig}" true
    DumpSpokeUpgradeStatus "paused"
    for hopPullspec in "${hopImages[@]}"; do
        hopPullspec="${hopPullspec//[[:space:]]/}"
        [[ -n "${hopPullspec}" ]]
        UpgradeSpokeToPullspec "${hopPullspec}"
    done
    WaitMcpCondition "${spokeKubeconfig}" worker 'Updated=False' 30m
    SetWorkerMcpPaused "${spokeKubeconfig}" false
    WaitMcpCondition "${spokeKubeconfig}" worker Updated "${ACM_SPOKE_UPGRADE_TIMEOUT}"
    DumpSpokeUpgradeStatus "unpaused"
else
    UpgradeSpokeToPullspec "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
fi

true
