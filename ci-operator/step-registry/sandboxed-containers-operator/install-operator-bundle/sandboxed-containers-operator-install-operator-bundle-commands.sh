#!/bin/bash
#
# Install the OpenShift Sandboxed Containers operator via OLM v1
# (ClusterExtension).
#
# Manifests are based on openshift/sandboxed-containers-operator PR 2762
# (config/olmv1/).  The step creates a ClusterCatalog from FBC_IMAGE,
# sets up the installer ServiceAccount / RBAC, then creates the
# ClusterExtension and waits for the operator deployment.
#

set -euo pipefail

NS="${OSC_NAMESPACE:-openshift-sandboxed-containers-operator}"

# ── Fail fast if FBC_IMAGE is not set ────────────────────────────────
if [[ -z "${FBC_IMAGE:-}" ]]; then
  echo "ERROR: FBC_IMAGE must be set to an FBC catalog image containing"
  echo "       the sandboxed-containers-operator bundle."
  echo "       Example: quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc:latest"
  exit 1
fi

echo "=== OSC OLM v1 Installation ==="
echo "  FBC image: ${FBC_IMAGE}"
echo "  Namespace: ${NS}"
echo "  Catalog:   ${CATALOG_NAME}"
echo "  Package:   ${PACKAGE_NAME}"

# ── 1. Namespace ─────────────────────────────────────────────────────
echo "Creating namespace ${NS}"
oc create namespace "$NS" 2>/dev/null || true

# ── 2. ClusterCatalog ────────────────────────────────────────────────
echo "Creating ClusterCatalog ${CATALOG_NAME}"
cat <<EOF | oc apply -f -
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  name: ${CATALOG_NAME}
spec:
  source:
    type: Image
    image:
      ref: ${FBC_IMAGE}
      pollIntervalMinutes: 1
EOF

echo "Waiting for ClusterCatalog ${CATALOG_NAME} to be ready..."
for i in {1..30}; do
  STATUS=$(oc get clustercatalog "${CATALOG_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Serving")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${STATUS}" == "True" ]]; then
    echo "ClusterCatalog is ready"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: ClusterCatalog ${CATALOG_NAME} not ready after 5 minutes"
    oc get clustercatalog "${CATALOG_NAME}" -o yaml || true
    exit 1
  fi
  echo "  Attempt ${i}/30: Serving=${STATUS}, waiting 10s..."
  sleep 10
done

# ── 3. ServiceAccount ────────────────────────────────────────────────
echo "Creating ServiceAccount sandboxed-containers-installer"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sandboxed-containers-installer
  namespace: ${NS}
EOF

# ── 4. ClusterRole (from PR 2762: config/olmv1/02-clusterrole.yaml) ──
echo "Creating ClusterRole sandboxed-containers-installer-role"
cat <<'ROLE_EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sandboxed-containers-installer-role
rules:
  # OLM v1: manage this ClusterExtension
  - apiGroups: [olm.operatorframework.io]
    resources: [clusterextensions/finalizers]
    verbs: [update]
    resourceNames: [sandboxed-containers]

  # OLM v1: manage ClusterObjectSets created for this extension
  - apiGroups: [olm.operatorframework.io]
    resources: [clusterobjectsets/finalizers]
    verbs: [update]

  # OLM v1: metrics endpoint
  - nonResourceURLs: [/metrics]
    verbs: [get]

  # CRDs owned by the operator
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [create, list, watch]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, update, patch, delete]
    resourceNames:
      - kataconfigs.kataconfiguration.openshift.io
      - peerpods.confidentialcontainers.org

  # RBAC resources the operator creates for its own controllers
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterroles, clusterrolebindings, roles, rolebindings]
    verbs: [create, list, watch]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterroles, clusterrolebindings, roles, rolebindings]
    verbs: [get, update, patch, delete]

  # Core resources (from CSV clusterPermissions)
  - apiGroups: [""]
    resources: [pods, pods/finalizers]
    verbs: [get, create, patch, update, list, watch]
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, update, list, watch]
  - apiGroups: [""]
    resources: [nodes/status]
    verbs: [patch]
  - apiGroups: [""]
    resources: [secrets, secrets/finalizers, secrets/status]
    verbs: [create, delete, get, list, patch, update, watch]
  - apiGroups: [""]
    resources: [serviceaccounts]
    verbs: [create, delete, get, list, patch, update, watch]
  - apiGroups: ["", machineconfiguration.openshift.io]
    resources:
      - configmaps
      - containerruntimeconfigs
      - endpoints
      - events
      - machineconfigpools
      - machineconfigs
      - nodes
      - persistentvolumeclaims
      - pods
      - secrets
      - services
      - services/finalizers
    verbs: [create, delete, get, list, patch, update, watch]

  # Leader election
  - apiGroups: [coordination.k8s.io]
    resources: [leases]
    verbs: [create, delete, get, list, patch, update, watch]

  # Webhook configurations (both validating and mutating)
  - apiGroups: [admissionregistration.k8s.io]
    resources: [validatingwebhookconfigurations, mutatingwebhookconfigurations]
    verbs: [create, delete, get, list, update, watch, patch]

  # Network policies
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [create, delete, update]

  # Workload resources
  - apiGroups: [apps]
    resources: [daemonsets, deployments, replicasets, statefulsets]
    verbs: [create, delete, get, list, patch, update, watch]
  - apiGroups: [apps]
    resources: [daemonsets/finalizers]
    verbs: [update]
    resourceNames: [manager-role]
  - apiGroups: [batch]
    resources: [jobs]
    verbs: [create, delete, get, list, watch]

  # Monitoring resources
  - apiGroups: [monitoring.coreos.com]
    resources: [prometheusrules, servicemonitors]
    verbs: [create, delete, get, list, patch, update, watch]

  # Cloud credential requests (peer-pods)
  - apiGroups: [cloudcredential.openshift.io]
    resources: [credentialsrequests]
    verbs: [create, delete, get, list]

  # Confidential containers / peer-pods CRs
  - apiGroups: [confidentialcontainers.org]
    resources:
      - peerpodconfigs
      - peerpods
      - pods
      - peerpodconfigs/finalizers
      - peerpods/finalizers
      - peerpodconfigs/status
      - peerpods/status
    verbs: [create, delete, get, list, patch, update, watch]

  # Cluster info
  - apiGroups: [config.openshift.io]
    resources: [apiservers, clusterversions, infrastructures]
    verbs: [get, list, watch]

  # Kata CRs
  - apiGroups: [kataconfiguration.openshift.io]
    resources: [kataconfigs, kataconfigs/finalizers, kataconfigs/status]
    verbs: [create, delete, get, list, patch, update, watch]

  # RuntimeClass
  - apiGroups: [node.k8s.io]
    resources: [runtimeclasses]
    verbs: [create, delete, get, list, patch, update, watch]

  # SCCs - create operator-managed SCCs
  - apiGroups: [security.openshift.io]
    resources: [securitycontextconstraints]
    verbs: [create]

  # SCCs - manage only operator-owned SCCs
  - apiGroups: [security.openshift.io]
    resources: [securitycontextconstraints]
    resourceNames:
      - sandboxed-containers-operator-scc
      - kata-install-scc
    verbs: [delete, patch, update, use, watch]

  # SCCs - read all SCCs to validate cluster state
  - apiGroups: [security.openshift.io]
    resources: [securitycontextconstraints]
    verbs: [get, list]

  # Token and access reviews for metrics auth
  - apiGroups: [authentication.k8s.io]
    resources: [tokenreviews]
    verbs: [create]
  - apiGroups: [authorization.k8s.io]
    resources: [subjectaccessreviews]
    verbs: [create]
ROLE_EOF

# ── 5. ClusterRoleBinding ────────────────────────────────────────────
echo "Creating ClusterRoleBinding sandboxed-containers-installer-binding"
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sandboxed-containers-installer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: sandboxed-containers-installer-role
subjects:
  - kind: ServiceAccount
    name: sandboxed-containers-installer
    namespace: ${NS}
EOF

# ── 6. ClusterExtension ─────────────────────────────────────────────
echo "Creating ClusterExtension sandboxed-containers"
cat <<EOF | oc apply -f -
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: sandboxed-containers
spec:
  namespace: ${NS}
  serviceAccount:
    name: sandboxed-containers-installer
  source:
    sourceType: Catalog
    catalog:
      packageName: ${PACKAGE_NAME}
      channels:
        - stable
      name: ${CATALOG_NAME}
      upgradeConstraintPolicy: CatalogProvided
EOF

# ── 7. Wait for ClusterExtension Installed ───────────────────────────
echo "Waiting for ClusterExtension to be installed..."
for i in {1..60}; do
  STATUS=$(oc get clusterextension sandboxed-containers \
    -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${STATUS}" == "True" ]]; then
    echo "ClusterExtension installed successfully"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "ERROR: ClusterExtension not installed after 10 minutes"
    oc get clusterextension sandboxed-containers -o yaml || true
    exit 1
  fi
  echo "  Attempt ${i}/60: Installed=${STATUS}, waiting 10s..."
  sleep 10
done

# ── 8. Wait for controller-manager deployment ────────────────────────
echo "Waiting for controller-manager deployment..."
oc wait --timeout=10m --for=condition=Available -n "$NS" \
  deployment/controller-manager

echo "=== sandboxed-containers-operator installed successfully via OLM v1 ==="
