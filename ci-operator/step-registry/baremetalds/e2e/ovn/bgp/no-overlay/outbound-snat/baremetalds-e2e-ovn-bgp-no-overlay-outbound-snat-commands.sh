#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds e2e ovn bgp no-overlay outbound-snat command ************"

TARGET="${NO_OVERLAY_OUTBOUND_SNAT:-Enabled}"

if [ "${TARGET}" != "Enabled" ] && [ "${TARGET}" != "Disabled" ]; then
    echo "ERROR: NO_OVERLAY_OUTBOUND_SNAT must be 'Enabled' or 'Disabled', got '${TARGET}'" >&2
    exit 1
fi

transport=$(oc get Network.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.transport}')
if [ "${transport}" != "NoOverlay" ]; then
    echo "ERROR: cluster transport is '${transport:-<unset>}', not NoOverlay: refusing to patch noOverlayConfig" >&2
    exit 1
fi

current=$(oc get Network.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.noOverlayConfig.outboundSNAT}')
echo "outboundSNAT is '${current:-<unset>}', target is '${TARGET}'"

if [ "${current}" = "${TARGET}" ]; then
    echo "Already at the target value, nothing to do"
    exit 0
fi

# CNO hashes outboundSNAT into this annotation on the ovnkube-node pod template
# (pkg/network/ovn_kubernetes.go, OVNKubeNodeConfigHash) precisely so that changing
# the field rolls the DaemonSet. Watching it is how we know CNO has reacted, rather
# than racing "oc rollout status" against a DaemonSet it has not updated yet.
hash_path='{.spec.template.metadata.annotations.network\.operator\.openshift\.io/ovnkube-node-config-hash}'
old_hash=$(oc get daemonset/ovnkube-node -n openshift-ovn-kubernetes -o jsonpath="${hash_path}")
echo "ovnkube-node config hash before the patch: ${old_hash:-<unset>}"

echo "Patching outboundSNAT to ${TARGET}..."
oc patch Network.operator.openshift.io cluster --type=merge \
    -p "{\"spec\":{\"defaultNetwork\":{\"ovnKubernetesConfig\":{\"noOverlayConfig\":{\"outboundSNAT\":\"${TARGET}\"}}}}}"

echo "Waiting for CNO to re-render ovnkube-node..."
deadline=$((SECONDS + 600))
while true; do
    new_hash=$(oc get daemonset/ovnkube-node -n openshift-ovn-kubernetes -o jsonpath="${hash_path}" 2>/dev/null || true)
    if [ -n "${new_hash}" ] && [ "${new_hash}" != "${old_hash}" ]; then
        echo "ovnkube-node config hash is now ${new_hash}"
        break
    fi
    if (( SECONDS >= deadline )); then
        echo "ERROR: timed out waiting for the ovnkube-node config hash to change" >&2
        oc get daemonset/ovnkube-node -n openshift-ovn-kubernetes -o yaml || true
        oc get co network -o yaml || true
        exit 1
    fi
    sleep 10
done

echo "Waiting for the ovnkube-node rollout..."
timeout 20m oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes

# Ensure the change actually took, if not no use proceeding with the test.
applied=$(oc get Network.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.noOverlayConfig.outboundSNAT}')
if [ "${applied}" != "${TARGET}" ]; then
    echo "ERROR: outboundSNAT is '${applied:-<unset>}' after the rollout, expected '${TARGET}'" >&2
    exit 1
fi

echo "outboundSNAT successfully changed to ${TARGET}"
