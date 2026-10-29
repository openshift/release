#!/bin/bash
set -euo pipefail

# Apply minimal stub CRDs required for the TALM (topology-aware-lifecycle-manager)
# controller-manager to start. TALM's main.go registers these ACM/MCE API types
# in its controller-runtime scheme at startup, and crashes immediately if any of
# the corresponding API groups are not present in the cluster.
#
# These stubs are intentionally minimal (no validation schema, no sub-resources)
# since TALM only needs the API groups to be discoverable - it does not require
# a running ACM/MCE hub for DAST purposes.

echo "Applying stub CRDs for TALM prerequisites..."

oc apply -f - <<'EOF'
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: managedclusters.cluster.open-cluster-management.io
spec:
  group: cluster.open-cluster-management.io
  names:
    kind: ManagedCluster
    listKind: ManagedClusterList
    plural: managedclusters
    singular: managedcluster
  scope: Cluster
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: manifestworks.work.open-cluster-management.io
spec:
  group: work.open-cluster-management.io
  names:
    kind: ManifestWork
    listKind: ManifestWorkList
    plural: manifestworks
    singular: manifestwork
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: manifestworkreplicasets.work.open-cluster-management.io
spec:
  group: work.open-cluster-management.io
  names:
    kind: ManifestWorkReplicaSet
    listKind: ManifestWorkReplicaSetList
    plural: manifestworkreplicasets
    singular: manifestworkreplicaset
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: policies.policy.open-cluster-management.io
spec:
  group: policy.open-cluster-management.io
  names:
    kind: Policy
    listKind: PolicyList
    plural: policies
    singular: policy
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: placementbindings.policy.open-cluster-management.io
spec:
  group: policy.open-cluster-management.io
  names:
    kind: PlacementBinding
    listKind: PlacementBindingList
    plural: placementbindings
    singular: placementbinding
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: managedclusterviews.view.open-cluster-management.io
spec:
  group: view.open-cluster-management.io
  names:
    kind: ManagedClusterView
    listKind: ManagedClusterViewList
    plural: managedclusterviews
    singular: managedclusterview
  scope: Namespaced
  versions:
  - name: v1beta1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: managedclusteractions.action.open-cluster-management.io
spec:
  group: action.open-cluster-management.io
  names:
    kind: ManagedClusterAction
    listKind: ManagedClusterActionList
    plural: managedclusteractions
    singular: managedclusteraction
  scope: Namespaced
  versions:
  - name: v1beta1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
EOF

echo "Waiting for CRDs to be established..."
for crd in \
  managedclusters.cluster.open-cluster-management.io \
  manifestworks.work.open-cluster-management.io \
  manifestworkreplicasets.work.open-cluster-management.io \
  policies.policy.open-cluster-management.io \
  placementbindings.policy.open-cluster-management.io \
  managedclusterviews.view.open-cluster-management.io \
  managedclusteractions.action.open-cluster-management.io
do
  oc wait crd "${crd}" --for=condition=Established --timeout=60s
  echo "  ${crd} - Established"
done

echo "All TALM prerequisite CRDs are ready."
