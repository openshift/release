#!/bin/bash
set -euo pipefail

# Stub CRDs for external API types watched by the oran-o2ims controller-manager.
#
# The controller registers informers (Owns/Watches) for CRDs from optional
# operators. If a CRD is absent, the informer cache sync times out after
# ~2 minutes and the entire manager crashes — taking down the metrics (6443)
# and webhook (9443) ports until the next restart cycle.
#
# Each CRD is created only if it does not already exist, so this step
# is safe to run on clusters where the real operator (e.g., TALM) is
# installed — it will not overwrite the operator's full CRD schema.
# Add new entries here when the operator gains watches on CRDs from
# additional optional operators.

echo "Checking prerequisite CRDs for oran-o2ims..."

# ImageBasedGroupUpgrade — from TALM (topology-aware-lifecycle-manager)
# Watched by: ProvisioningRequest controller (Owns)
# Jira: https://issues.redhat.com/browse/CNF-24426
if oc get crd imagebasedgroupupgrades.lcm.openshift.io &>/dev/null; then
  echo "  imagebasedgroupupgrades.lcm.openshift.io — already exists (TALM installed), skipping stub"
else
  echo "  imagebasedgroupupgrades.lcm.openshift.io — not found, applying stub CRD"
  oc create -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: imagebasedgroupupgrades.lcm.openshift.io
  labels:
    oran-o2ims/prereq-stub: "true"
spec:
  group: lcm.openshift.io
  names:
    kind: ImageBasedGroupUpgrade
    listKind: ImageBasedGroupUpgradeList
    plural: imagebasedgroupupgrades
    singular: imagebasedgroupupgrade
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
EOF
fi

echo "Waiting for prerequisite CRDs to be established..."
if ! oc wait crd imagebasedgroupupgrades.lcm.openshift.io --for=condition=Established --timeout=60s; then
  echo "ERROR: imagebasedgroupupgrades.lcm.openshift.io did not become Established within 60s"
  oc get crd imagebasedgroupupgrades.lcm.openshift.io -o yaml 2>&1 || true
  exit 1
fi
echo "  imagebasedgroupupgrades.lcm.openshift.io — Established"

echo "All prerequisite CRDs are ready."
