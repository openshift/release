#!/bin/bash
#
# Upgrades the ACM managed spoke cluster (single spoke from cluster-install).
# Spoke direct: channel patch, admin-ack, klusterlet-work RBAC bootstrap, oc wait.
# Hub ManifestWork: ClusterVersion desiredUpdate.image only.
# Requires acm-fetch-managed-clusters (${SHARED_DIR}/kubeconfig) and
# acm-interop-p2p-cluster-install (${SHARED_DIR}/managed-cluster-kubeconfig,
# ${SHARED_DIR}/managed-cluster-name).
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

typeset releaseInfoJson targetVersion digest imgRepo spokeImage hubKubeconfig spokeKubeconfig spokeName
releaseInfoJson="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" -o json)"
targetVersion="$(jq -r '.metadata.version' <<<"${releaseInfoJson}")"
digest="$(jq -r '.digest' <<<"${releaseInfoJson}")"
[[ -n "${targetVersion}" ]]
[[ -n "${digest}" ]]
imgRepo="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE%:*}"
imgRepo="${imgRepo%@sha256*}"
spokeImage="${imgRepo}@${digest}"
hubKubeconfig="${SHARED_DIR}/kubeconfig"
spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
spokeName="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")"
[[ -n "${spokeName}" ]]

ClearBlockingOdfVersionConstraints() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    # ODF CSVs declare maxOCPVersion: 4.23, blocking upgrades to 5.0 (OCP 5.0 ≡ 4.23 semantically).
    # Rather than patching metadata, delete the offending CSVs before upgrade.
    # OLM will auto-recover by pulling a compatible version from the catalog after the upgrade completes.
    # This is safe because ODF is already installed and functional; the CSVs are just metadata.
    typeset csvName=''
    for csvName in odf-dependencies.v4.22.2-rhodf odf-operator.v4.22.2-rhodf; do
        if oc --kubeconfig="${kubeconfig}" get csv "${csvName}" \
            -n openshift-storage --ignore-not-found >/dev/null 2>&1; then
            : "Deleting ${csvName} to clear OCP version constraint before upgrade"
            oc --kubeconfig="${kubeconfig}" delete csv "${csvName}" \
                -n openshift-storage --ignore-not-found
        else
            : "CSV ${csvName} not found; skipping deletion"
        fi
    done
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
    elif grep -q "cluster version overrides" <<<"${upgradeableMsg}"; then
        # CVO blocks minor/major upgrades when spec.overrides is non-empty.
        # Clear all overrides so the CVO can transition to Completed after the upgrade.
        # This is safe here because overrides are only set during provisioning
        # (e.g. by DisableClusterImagePolicySignatureEnforcement) and are no longer
        # needed once the spoke is registered and we are about to upgrade it.
        : "Upgradeable blocked by spec.overrides — clearing before minor upgrade"
        oc --kubeconfig="${kubeconfig}" patch clusterversion version --type merge \
            -p '{"spec":{"overrides":null}}'
        : "Overrides cleared; cluster should now be Upgradeable"
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
          image: ${spokeImage}
EOF
    : "Applying ManifestWork ${mwName} in namespace ${mwNamespace} on hub"
    KUBECONFIG="${hubKubeconfig}" oc apply -f "${manifestFile}"
    true
}

WaitSpokeUpgradeCompleted() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    : "Waiting for spoke ClusterVersion ${targetVersion} to reach Completed (${ACM_SPOKE_UPGRADE_TIMEOUT})"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].version}'="${targetVersion}" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].state}'="Completed" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}"
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

# Clear ODF version constraints before upgrade (ODF CSVs declare maxOCPVersion: 4.23, blocking 5.0 upgrades).
# This must run before PatchAdminAcksForUpgrade so OLM can fully reconcile post-upgrade.
ClearBlockingOdfVersionConstraints "${spokeKubeconfig}"

PatchAdminAcksForUpgrade "${spokeKubeconfig}"
ApplySpokeClusterVersionRbac "${spokeKubeconfig}" "${rbacManifest}"
ApplySpokeUpgradeManifestWork "${spokeName}" "${ACM_MANIFESTWORK_NAME}" "${mwManifest}"
WaitSpokeUpgradeCompleted "${spokeKubeconfig}"

true
