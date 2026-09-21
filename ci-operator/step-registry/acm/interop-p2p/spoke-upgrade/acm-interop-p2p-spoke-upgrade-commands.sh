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
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq yq

[ -f "${SHARED_DIR}/kubeconfig" ]
[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
[ -f "${SHARED_DIR}/managed-cluster-name" ]

typeset hubKubeconfig="${SHARED_DIR}/kubeconfig"
typeset spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
typeset spokeName=''
spokeName="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")"
[[ -n "${spokeName}" ]]

typeset currentHopVersion=''
# Writes spoke upgrade failure diagnostics to the artifact directory.
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
        oc --kubeconfig="${spokeKubeconfig}" get nodes \
            -o custom-columns='STATUS:.status.conditions[?(@.type=="Ready")].status,VERSION:.status.nodeInfo.kubeletVersion,OS-IMAGE:.status.nodeInfo.osImage' \
            2>&1 || true
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

# Resolve release image metadata (version, digest, image) from a pullspec.
# Sets caller-scoped namerefs: versionRef, imageRef.
ResolveReleaseImage() {
    typeset pullspec="${1:?}"; (($#)) && shift
    typeset -n versionRef="${1:?}"; (($#)) && shift
    typeset -n imageRef="${1:?}"; (($#)) && shift
    typeset releaseInfoJson='' digest='' imgRepo=''
    releaseInfoJson="$(oc adm release info "${pullspec}" -o json)"
    versionRef="$(jq -r '.metadata.version' <<<"${releaseInfoJson}")"
    digest="$(jq -r '.digest' <<<"${releaseInfoJson}")"
    [[ -n "${versionRef}" ]] || { : "ResolveReleaseImage: empty version for pullspec '${pullspec}'"; exit 1; }
    [[ -n "${digest}" ]]     || { : "ResolveReleaseImage: empty digest for pullspec '${pullspec}'"; exit 1; }
    imgRepo="${pullspec%:*}"
    imgRepo="${imgRepo%@sha256*}"
    imageRef="${imgRepo}@${digest}"
    true
}

# Patches admin-acks ConfigMap for the given spoke kubeconfig.
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

WaitSpokeVersionAppears() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset version="${1:?}"; (($#)) && shift
    # Only waits for the version entry to appear in history (state may be Partial).
    # Use this during CPOU hops where the worker MCP is paused — ClusterVersion state
    # stays Partial until workers are upgraded, so waiting for Completed here would
    # time out.  Call WaitSpokeUpgradeCompleted after workers are unpaused.
    : "Waiting for spoke ClusterVersion ${version} version entry (${ACM_SPOKE_UPGRADE_TIMEOUT})"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].version}'="${version}" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}" 1>/dev/null
    true
}

WaitSpokeUpgradeCompleted() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset version="${1:?}"; (($#)) && shift
    : "Waiting for spoke ClusterVersion ${version} version entry (${ACM_SPOKE_UPGRADE_TIMEOUT})"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].version}'="${version}" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}" 1>/dev/null
    # Once the target version entry appears, Completed follows after operators reconcile.
    # Use a separate ceiling so we don't consume the full main timeout a second time.
    : "Waiting for spoke ClusterVersion ${version} state=Completed (${ACM_SPOKE_UPGRADE_COMPLETION_TIMEOUT})"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].state}'="Completed" \
        --timeout="${ACM_SPOKE_UPGRADE_COMPLETION_TIMEOUT}" 1>/dev/null
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
        --timeout="${timeout}" 1>/dev/null
    true
}


SetWorkerMcpPaused() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset isPaused="${1:?}"; (($#)) && shift
    typeset actual=''
    : "Setting spoke mcp/worker spec.paused=${isPaused}"
    oc --kubeconfig="${kubeconfig}" patch mcp/worker --type merge \
        -p "$(jq -cn --argjson p "${isPaused}" '{"spec":{"paused":$p}}')"
    actual="$(oc --kubeconfig="${kubeconfig}" get mcp/worker -o jsonpath='{.spec.paused}')"
    [[ "${actual}" == "${isPaused}" ]]
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

# Ensures the 'openshift' ClusterImagePolicy does not enforce Sigstore signatures
# for openshift-release-dev images before spoke workers are unpaused.
#
# Root cause (OCPBUGS-114622 / INTEROP-9516 follow-up):
#   DisableClusterImagePolicySignatureEnforcement in cluster-install runs at OCP 4.20
#   install time when no CIP exists yet. After the CPOU hop to 4.21, CVO creates the
#   'openshift' CIP, and MCO bakes Sigstore enforcement into each node's
#   /etc/containers/policy.json. When workers are later unpaused they try to pull the
#   unsigned nightly 4.22 OS image (quay.io/openshift-release-dev/ocp-v4.0-art-dev)
#   and fail: "A signature was required, but no signature exists".
#
# This function acts as a defence-in-depth safety net:
#   1. Re-asserts the CVO override (guards against it being lost, e.g. via ManifestWork SSA).
#   2. Deletes the CIP if it was created during the 4.21 hop.
#   3. Waits for MCO to re-render master MCP so the corrected policy.json (no Sigstore)
#      is ready for workers to pick up when they are unpaused.
DisableSpokeClusterImagePolicy() {
    typeset cipJson='' currentOverrides='' newOverrides=''

    # Step 1: set the CVO override unconditionally so CVO cannot (re)create the CIP.
    : "Spoke ${spokeName}: ensuring openshift ClusterImagePolicy is marked unmanaged in CVO overrides"
    currentOverrides="$(oc --kubeconfig="${spokeKubeconfig}" get clusterversion version -o json |
        jq -c '.spec.overrides // []')"
    if jq -e '.[] | select(
            .group=="config.openshift.io" and
            .kind=="ClusterImagePolicy" and
            .name=="openshift" and
            .namespace=="" and
            .unmanaged==true)' \
            <<<"${currentOverrides}" >/dev/null; then
        : "Spoke ${spokeName}: ClusterImagePolicy already unmanaged in CVO overrides"
    else
        newOverrides="$(jq -c \
            '[.[] | select(
                .group!="config.openshift.io" or
                .kind!="ClusterImagePolicy" or
                .name!="openshift" or
                .namespace!=""
            )] + [{"group":"config.openshift.io","kind":"ClusterImagePolicy","name":"openshift","namespace":"","unmanaged":true}]' \
        <<<"${currentOverrides}")"
        oc --kubeconfig="${spokeKubeconfig}" patch clusterversion version --type merge \
            -p "$(jq -cn --argjson o "${newOverrides}" '{"spec":{"overrides":$o}}')" 1>/dev/null
        : "Spoke ${spokeName}: CVO override set — openshift ClusterImagePolicy → unmanaged"
    fi

    # Step 2: delete the CIP if it exists with openshift-release-dev scope.
    cipJson="$(oc --kubeconfig="${spokeKubeconfig}" get clusterimagepolicy openshift \
        --ignore-not-found -o json)"
    if [[ -z "${cipJson}" ]]; then
        : "Spoke ${spokeName}: no openshift ClusterImagePolicy present — CVO override is sufficient"
        return 0
    fi
    if ! jq -e '.spec.scopes[]? | select(contains("openshift-release-dev"))' \
            <<<"${cipJson}" >/dev/null; then
        : "Spoke ${spokeName}: ClusterImagePolicy does not scope openshift-release-dev — skipping deletion"
        return 0
    fi

    : "Spoke ${spokeName}: deleting openshift ClusterImagePolicy — removing Sigstore enforcement from MCO"
    oc --kubeconfig="${spokeKubeconfig}" delete clusterimagepolicy openshift \
        --ignore-not-found 1>/dev/null

    # Step 3: wait for MCO to re-render the master MCP with the updated policy.json.
    # In EUS mode workers are still paused; they receive the re-rendered config (no Sigstore)
    # when unpaused.  In n+1 mode this re-render completes before the upgrade begins, so
    # masters can pull the unsigned target OS image without signature enforcement.
    # || true: if master MCO config didn't change (no other diff), skip gracefully.
    WaitMcpCondition "${spokeKubeconfig}" master Updating "${ACM_SPOKE_MCP_CHANGE_TIMEOUT_SECONDS}s" || true
    WaitMcpCondition "${spokeKubeconfig}" master Updated "${ACM_SPOKE_UPGRADE_TIMEOUT}"
    : "Spoke ${spokeName}: ClusterImagePolicy signature enforcement disabled"
    true
}

# Upgrade the spoke cluster to a specific release pullspec.
# Sets caller-scoped variable (arg 2) to the resolved hop version
# so the trap handler can report which hop was in progress on failure.
# Only waits for the version entry (state may be Partial) — callers are responsible
# for waiting for state=Completed after workers are unpaused (EUS) or immediately (n+1).
UpgradeSpokeToPullspec() {
    typeset pullspec="${1:?}"; (($#)) && shift
    typeset -n currentHopVersionRef="${1:?}"; (($#)) && shift
    typeset hopVersion='' hopImage=''
    ResolveReleaseImage "${pullspec}" hopVersion hopImage
    currentHopVersionRef="${hopVersion}"
    : "Upgrading spoke ${spokeName} to ${hopVersion}"
    PatchAdminAcksForUpgrade "${spokeKubeconfig}"
    ApplySpokeUpgradeManifestWork "${spokeName}" "${ACM_MANIFESTWORK_NAME}" \
        "${mwManifest}" "${hopImage}"
    WaitSpokeVersionAppears "${spokeKubeconfig}" "${hopVersion}"
    # Guard against stale Updated=True from the prior hop: MCO sets its operator version
    # only after it has rolled out the new rendered configs to the master pool.
    # Waiting for this version ensures the subsequent master Updated wait reflects
    # the current hop, not a stale condition from the previous hop.
    : "Waiting for machine-config ClusterOperator to report version ${hopVersion}"
    oc --kubeconfig="${spokeKubeconfig}" wait clusteroperator/machine-config \
        --for=jsonpath='{.status.versions[?(@.name=="operator")].version}'="${hopVersion}" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}" 1>/dev/null
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

if [[ "${SPOKE_CLUSTER_UPGRADE_EUS}" == 'true' ]]; then
    typeset hopPullspecs='' hopPullspec=''
    typeset -a hopImagesArr=()
    [ -f "${SHARED_DIR}/upgrade-edge" ]
    hopPullspecs="$(< "${SHARED_DIR}/upgrade-edge")"
    [[ -n "${hopPullspecs}" ]] || { : "upgrade-edge is empty; cucushift-upgrade-setedge-2hops must run before this step"; exit 1; }
    IFS=',' read -r -a hopImagesArr <<< "${hopPullspecs}"
    (( ${#hopImagesArr[@]} >= 2 )) || { : "upgrade-edge requires at least 2 hop images; got ${#hopImagesArr[@]}"; exit 1; }
    : "EUS CPOU spoke upgrade via ${#hopImagesArr[@]} hops from upgrade-edge"
    SetWorkerMcpPaused "${spokeKubeconfig}" true
    DumpSpokeUpgradeStatus "paused"
    for hopPullspec in "${hopImagesArr[@]}"; do
        hopPullspec="${hopPullspec//[[:space:]]/}"
        [[ -n "${hopPullspec}" ]] || { : "Empty/whitespace-only pullspec in upgrade-edge; check upgrade-edge content"; exit 1; }
        UpgradeSpokeToPullspec "${hopPullspec}" currentHopVersion
        # Remove any CIP created by this hop before the next hop pulls unsigned images.
        # CVO may create the 'openshift' CIP during the 4.21 hop (OCPBUGS-114622); if it
        # is not cleaned up here, masters will fail to pull the unsigned 4.22 OS image on
        # the next hop and WaitMcpCondition master Updated inside UpgradeSpokeToPullspec
        # will time out before any post-loop call could help.
        DisableSpokeClusterImagePolicy
        # Re-apply the target channel after each hop so the CVO's Upgradeable condition
        # and update graph reflect the final EUS target (idempotent if already set).
        if [[ -n "${SPOKE_CLUSTER_UPGRADE_TARGET_CHANNEL}" ]]; then
            : "Re-applying channel ${SPOKE_CLUSTER_UPGRADE_TARGET_CHANNEL} after hop to ${currentHopVersion}"
            oc --kubeconfig="${spokeKubeconfig}" patch clusterversion version --type merge \
                -p "$(jq -cn --arg ch "${SPOKE_CLUSTER_UPGRADE_TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"
        fi
    done
    WaitMcpCondition "${spokeKubeconfig}" worker 'Updated=False' "${ACM_SPOKE_UPGRADE_TIMEOUT}"
    SetWorkerMcpPaused "${spokeKubeconfig}" false
    WaitMcpCondition "${spokeKubeconfig}" worker Updated "${ACM_SPOKE_UPGRADE_TIMEOUT}"
    # Workers are now upgraded — CVO can finally mark the last hop Completed.
    WaitSpokeUpgradeCompleted "${spokeKubeconfig}" "${currentHopVersion}"
    DumpSpokeUpgradeStatus "unpaused"
else
    # Defense-in-depth for n+1 (e.g. 4.21→4.22): the 'openshift' CIP exists on 4.21 spokes
    # and cluster-install removes it, but re-assert here so a recreated or leftover CIP
    # cannot block masters from pulling the unsigned target OS image during the upgrade.
    # The function is idempotent: if the CVO override is already set and no CIP exists it
    # returns immediately without any waits.
    DisableSpokeClusterImagePolicy
    UpgradeSpokeToPullspec "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" currentHopVersion
    # n+1: workers were never paused, so Completed can be checked immediately.
    WaitSpokeUpgradeCompleted "${spokeKubeconfig}" "${currentHopVersion}"
fi

true
