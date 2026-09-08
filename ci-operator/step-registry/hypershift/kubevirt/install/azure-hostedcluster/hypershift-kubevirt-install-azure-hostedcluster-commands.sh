#!/usr/bin/env bash
#
# Install KubeVirt (OpenShift CNV) on Azure hosted cluster
# Adapted for CI environment from manual installation script
#

set -euo pipefail

# Configuration from environment variables (set in ref.yaml)
CNV_SUBSCRIPTION_SOURCE="${CNV_SUBSCRIPTION_SOURCE:-redhat-operators}"
CNV_SUBSCRIPTION_CHANNEL="${CNV_SUBSCRIPTION_CHANNEL:-stable}"
AZURE_STORAGE_SKU="${AZURE_STORAGE_SKU:-PremiumV2_LRS}"
AZURE_DEFAULT_IOPS="${AZURE_DEFAULT_IOPS:-3000}"
AZURE_DEFAULT_THROUGHPUT="${AZURE_DEFAULT_THROUGHPUT:-125}"

echo "============================================"
echo "Installing KubeVirt on Azure Hosted Cluster"
echo "============================================"
echo "CNV source: ${CNV_SUBSCRIPTION_SOURCE}"
echo "CNV channel: ${CNV_SUBSCRIPTION_CHANNEL}"
echo "Azure storage SKU: ${AZURE_STORAGE_SKU}"
if [[ "${AZURE_STORAGE_SKU}" == "PremiumV2_LRS" ]]; then
  echo "Premium v2 IOPS: ${AZURE_DEFAULT_IOPS}"
  echo "Premium v2 throughput: ${AZURE_DEFAULT_THROUGHPUT} MB/s"
fi
echo

# Use management cluster kubeconfig from SHARED_DIR
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"

# Verify cluster access
echo "Verifying management cluster access..."
if ! oc get clusterversion >/dev/null 2>&1; then
  echo "ERROR: Cannot access management cluster with KUBECONFIG=${KUBECONFIG}"
  exit 1
fi

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | awk -F "." '{print $1"."$2}')
echo "Detected OCP version: ${OCP_VERSION}"
echo

# Step 1: Enable wildcard routes (required for KubeVirt)
echo "[1/6] Enabling wildcard routes..."
oc patch ingresscontroller -n openshift-ingress-operator default --type=json \
  -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'
echo "✓ Wildcard routes enabled"
echo

# Step 2: Configure Azure storage class
echo "[2/6] Configuring Azure storage class..."
if [[ "${AZURE_STORAGE_SKU}" == "PremiumV2_LRS" ]]; then
  # Check if StorageClass already exists
  if oc get sc managed-csi-premium-v2 &>/dev/null; then
    echo "  ⓘ Premium SSD v2 storage class already exists, skipping creation..."
  else
    echo "  Creating Premium SSD v2 storage class..."
    cat <<EOF | oc create -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-premium-v2
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: disk.csi.azure.com
parameters:
  skuname: PremiumV2_LRS
  cachingMode: None
  diskIOPSReadWrite: "${AZURE_DEFAULT_IOPS}"
  diskMBpsReadWrite: "${AZURE_DEFAULT_THROUGHPUT}"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
    echo "  ✓ Premium SSD v2 storage class created"
  fi

  # Remove default annotation from managed-csi
  echo "  Removing default annotation from managed-csi..."
  oc annotate sc managed-csi storageclass.kubernetes.io/is-default-class- 2>/dev/null || true

  # Ensure our StorageClass is marked as default
  oc annotate sc managed-csi-premium-v2 storageclass.kubernetes.io/is-default-class=true --overwrite

  STORAGE_CLASS_NAME="managed-csi-premium-v2"
  echo "  ✓ Premium SSD v2 storage class configured and set as default"
else
  # Use existing Premium_LRS (managed-csi)
  STORAGE_CLASS_NAME="managed-csi"
  echo "  ✓ Using existing Premium_LRS storage class (managed-csi)"
fi
echo

# Step 3: Create CNV namespace and operator group
echo "[3/6] Creating openshift-cnv namespace and operator group..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cnv-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
EOF
echo "✓ Namespace and operator group created"
echo

# Step 4: Subscribe to CNV operator
echo "[4/6] Creating CNV operator subscription (channel: ${CNV_SUBSCRIPTION_CHANNEL})..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/kubevirt-hyperconverged.openshift-cnv: ''
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: ${CNV_SUBSCRIPTION_CHANNEL}
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: ${CNV_SUBSCRIPTION_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for CSV to be installed..."
sleep 30

RETRIES=30
CSV=""
for i in $(seq ${RETRIES}); do
  if [[ -z ${CSV} ]]; then
    CSV=$(oc get subscription -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  fi

  if [[ -n ${CSV} ]]; then
    PHASE=$(oc get csv -n openshift-cnv ${CSV} -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "✓ CNV operator installed successfully (CSV: ${CSV})"
      break
    else
      echo "  Try ${i}/${RETRIES}: CSV ${CSV} phase is '${PHASE}', waiting..."
    fi
  else
    echo "  Try ${i}/${RETRIES}: Waiting for CSV to appear..."
  fi

  sleep 30
done

if [[ $(oc get csv -n openshift-cnv ${CSV} -o jsonpath='{.status.phase}' 2>/dev/null) != "Succeeded" ]]; then
  echo "ERROR: Failed to deploy CNV operator"
  echo
  echo "=== CSV Status ==="
  oc get csv -n openshift-cnv ${CSV} -o yaml
  exit 1
fi
echo

# Step 5: Deploy HyperConverged CR
echo "[5/6] Deploying HyperConverged custom resource..."
oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  featureGates:
    enableCommonBootImageImport: false
  logVerbosityConfig:
    kubevirt:
      virtLauncher: 8
      virtHandler: 8
      virtController: 8
      virtApi: 8
      virtOperator: 8
EOF

echo "Waiting for HyperConverged to become available (timeout: 15m)..."
if oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=15m; then
  echo "✓ HyperConverged resource is available"
else
  echo "ERROR: HyperConverged failed to become available"
  oc get hyperconverged -n openshift-cnv kubevirt-hyperconverged -o yaml
  exit 1
fi
echo

# Step 6: Apply Azure-specific configurations
echo "[6/6] Applying Azure-specific configurations..."

# Wait for CDI to create the StorageProfile
echo "  Waiting for StorageProfile to be created by CDI (timeout: 2m)..."
STORAGE_PROFILE_RETRIES=12
STORAGE_PROFILE_FOUND=false
for i in $(seq ${STORAGE_PROFILE_RETRIES}); do
  if oc get storageprofile ${STORAGE_CLASS_NAME} &>/dev/null; then
    STORAGE_PROFILE_FOUND=true
    echo "  ✓ StorageProfile ${STORAGE_CLASS_NAME} found"
    break
  else
    echo "  Try ${i}/${STORAGE_PROFILE_RETRIES}: Waiting for StorageProfile ${STORAGE_CLASS_NAME}..."
    sleep 10
  fi
done

if [[ "${STORAGE_PROFILE_FOUND}" == "false" ]]; then
  echo "  ERROR: StorageProfile ${STORAGE_CLASS_NAME} was not created by CDI within timeout"
  exit 1
fi

# Check and patch StorageProfile capabilities
echo "  Checking ${STORAGE_CLASS_NAME} StorageProfile capabilities..."
CLAIM_SETS=$(oc get storageprofile ${STORAGE_CLASS_NAME} -o jsonpath='{.spec.claimPropertySets}')
if echo "$CLAIM_SETS" | grep -q "Filesystem"; then
  echo "  ✓ ${STORAGE_CLASS_NAME} already supports Filesystem volumeMode"
else
  echo "  ⚠ ${STORAGE_CLASS_NAME} only advertises Block mode, patching to add Filesystem..."
  oc patch storageprofile ${STORAGE_CLASS_NAME} --type=merge -p \
    '{"spec":{"claimPropertySets":[{"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem"},{"accessModes":["ReadWriteOnce"],"volumeMode":"Block"}]}}'
  echo "  ✓ ${STORAGE_CLASS_NAME} StorageProfile patched"
fi

# Pin CPU model to Broadwell for Azure (avoid CPU model mismatches)
echo "  Pinning CPU model to Broadwell for Azure compatibility..."
MAX_RETRIES=5
for ((i=1; i<=MAX_RETRIES; i++)); do
  if oc patch hco kubevirt-hyperconverged -n openshift-cnv --type=json \
    -p='[{"op": "add", "path": "/spec/defaultCPUModel", "value": "Broadwell"}]'; then
    echo "  ✓ CPU model pinned to Broadwell"
    break
  else
    if [[ $i -lt $MAX_RETRIES ]]; then
      echo "  Patch failed, retrying in 2 seconds..."
      sleep 2
    else
      echo "  ERROR: Patch failed after $MAX_RETRIES attempts"
      exit 1
    fi
  fi
done

# Install VM console logger for debugging (opt-in only)
if [[ "${INSTALL_VM_CONSOLE_LOGGER:-false}" == "true" ]]; then
  echo "  Installing VM console logger..."
  if oc apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    openshift.io/sa.scc.mcs: s0:c27,c4
    openshift.io/sa.scc.supplemental-groups: 1000710000/10000
    openshift.io/sa.scc.uid-range: 1000710000/10000
  name: vm-logger
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vm-console-debug-launcher
  namespace: vm-logger
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vm-console-debug-launcher
rules:
- apiGroups: [""]
  resources: ["pods","serviceaccounts"]
  verbs: ["*"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles","rolebindings"]
  verbs: ["*"]
- apiGroups: ["kubevirt.io"]
  resources: ["virtualmachines"]
  verbs: ["list", "get"]
- apiGroups: ["subresources.kubevirt.io"]
  resources: ["virtualmachineinstances/console"]
  verbs: ["get", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vm-console-debug-launcher
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vm-console-debug-launcher
subjects:
- kind: ServiceAccount
  name: vm-console-debug-launcher
  namespace: vm-logger
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vm-console-debug-launcher
  namespace: vm-logger
spec:
  selector:
    matchLabels:
      app: vm-console-debug-launcher
  replicas: 1
  template:
    metadata:
      labels:
        app: vm-console-debug-launcher
    spec:
      containers:
      - command:
        - /usr/bin/vm-console-dbug-launcher.sh
        stdin: true
        tty: true
        # Note: Consider using a pinned digest (image@sha256:...) for production
        image: quay.io/dvossel/kubevirt-console-debugger:latest
        imagePullPolicy: IfNotPresent
        name: dbug
        resources:
          requests:
            cpu: 10m
            memory: 100Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
      restartPolicy: Always
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      serviceAccount: vm-console-debug-launcher
      serviceAccountName: vm-console-debug-launcher
EOF
  then
    echo "  ✓ VM console logger installed"
  else
    echo "  ⚠ Warning: Failed to install VM console logger"
    exit 1
  fi
else
  echo "  ⓘ VM console logger installation skipped (set INSTALL_VM_CONSOLE_LOGGER=true to enable)"
fi
echo

echo "============================================"
echo "✓ KubeVirt installation complete!"
echo "============================================"
echo
echo "Storage configuration:"
echo "  Default storage class: ${STORAGE_CLASS_NAME}"
echo "  Storage SKU: ${AZURE_STORAGE_SKU}"
if [[ "${AZURE_STORAGE_SKU}" == "PremiumV2_LRS" ]]; then
  echo "  IOPS: ${AZURE_DEFAULT_IOPS}"
  echo "  Throughput: ${AZURE_DEFAULT_THROUGHPUT} MB/s"
fi
echo

echo "Installation verification:"
oc get csv -n openshift-cnv
echo
oc get hyperconverged -n openshift-cnv
echo
oc get sc
echo
