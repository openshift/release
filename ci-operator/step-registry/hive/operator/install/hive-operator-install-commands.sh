#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing Hive operator using pre-merge image..."

# Use HIVE_IMAGE from dependencies (built from the PR being tested)
HIVE_IMAGE="${HIVE_IMAGE:-${HIVE_OPERATOR_IMAGE}}"
echo "Using Hive image: ${HIVE_IMAGE}"

# Clean up any existing Hive installation to avoid leader election conflicts
echo "Cleaning up any existing Hive installation..."
if oc get namespace hive &>/dev/null; then
  echo "Found existing hive namespace, deleting..."
  oc delete namespace hive --timeout=3m || {
    echo "WARNING: Namespace deletion timed out or failed, attempting force cleanup..."
    # Remove finalizers if namespace is stuck
    oc get namespace hive -o json | jq '.spec.finalizers = []' | oc replace --raw /api/v1/namespaces/hive/finalize -f - || true
    sleep 5
  }
  # Wait for namespace to be fully deleted
  echo "Waiting for namespace deletion to complete..."
  WAIT_COUNT=0
  while oc get namespace hive &>/dev/null && [ $WAIT_COUNT -lt 30 ]; do
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done
  if oc get namespace hive &>/dev/null; then
    echo "WARNING: Hive namespace still exists after cleanup attempt"
  else
    echo "Hive namespace successfully deleted"
  fi
fi

# Clean up any stale leader election leases
echo "Cleaning up any stale leader election resources..."
oc delete lease hive-operator-leader -n hive --ignore-not-found=true || true

# Create hive namespace
echo "Creating hive namespace..."
oc create namespace hive

# Create CRDs
echo "Creating Hive CRDs..."
cat <<EOF | oc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: hiveconfigs.hive.openshift.io
spec:
  group: hive.openshift.io
  names:
    kind: HiveConfig
    listKind: HiveConfigList
    plural: hiveconfigs
    singular: hiveconfig
  scope: Cluster
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              managedDomains:
                type: array
                items:
                  type: string
              targetNamespace:
                type: string
              logLevel:
                type: string
              featureGates:
                type: object
                properties:
                  enabled:
                    type: array
                    items:
                      type: string
          status:
            type: object
            x-kubernetes-preserve-unknown-fields: true
EOF

# Deploy Hive operator
echo "Deploying Hive operator with image: ${HIVE_IMAGE}..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hive-operator
  namespace: hive
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hive-operator
rules:
- apiGroups:
  - ""
  resources:
  - "*"
  verbs:
  - "*"
- apiGroups:
  - "apps"
  resources:
  - "*"
  verbs:
  - "*"
- apiGroups:
  - "apiextensions.k8s.io"
  resources:
  - "*"
  verbs:
  - "*"
- apiGroups:
  - "hive.openshift.io"
  resources:
  - "*"
  verbs:
  - "*"
- apiGroups:
  - "rbac.authorization.k8s.io"
  resources:
  - "*"
  verbs:
  - "*"
- apiGroups:
  - "admission.hive.openshift.io"
  resources:
  - "*"
  verbs:
  - "*"
- apiGroups:
  - "batch"
  resources:
  - "*"
  verbs:
  - "*"
- apiGroups:
  - "coordination.k8s.io"
  resources:
  - "*"
  verbs:
  - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hive-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hive-operator
subjects:
- kind: ServiceAccount
  name: hive-operator
  namespace: hive
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hive-operator
  namespace: hive
  labels:
    app: hive-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hive-operator
  template:
    metadata:
      labels:
        app: hive-operator
    spec:
      serviceAccountName: hive-operator
      containers:
      - name: hive-operator
        image: ${HIVE_IMAGE}
        command:
        - /opt/services/hive-operator
        - --log-level
        - info
        env:
        - name: CLI_CACHE_DIR
          value: /var/cache/kubectl
        - name: HIVE_OPERATOR_NS
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        imagePullPolicy: Always
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
        volumeMounts:
        - name: kubectl-cache
          mountPath: /var/cache/kubectl
      volumes:
      - name: kubectl-cache
        emptyDir: {}
EOF

# Wait for operator to be ready
echo "Waiting for Hive operator deployment to be available..."
oc wait --for=condition=Available --timeout=10m deployment/hive-operator -n hive

# Verify operator acquired leadership
echo "Verifying Hive operator acquired leadership..."
sleep 15
LEADER_CHECK_COUNT=0
LEADER_ACQUIRED=false
while [ $LEADER_CHECK_COUNT -lt 12 ]; do
  if oc logs -n hive deployment/hive-operator --tail=50 | grep -q "successfully acquired lease\|became leader"; then
    echo "Hive operator successfully acquired leadership"
    LEADER_ACQUIRED=true
    break
  fi
  if oc logs -n hive deployment/hive-operator --tail=50 | grep -q "current leader:" | grep -v "attempting to acquire"; then
    echo "WARNING: Another leader detected, waiting..."
  fi
  sleep 5
  LEADER_CHECK_COUNT=$((LEADER_CHECK_COUNT + 1))
done

if [ "$LEADER_ACQUIRED" = false ]; then
  echo "WARNING: Could not confirm operator leadership acquisition"
  echo "Recent operator logs:"
  oc logs -n hive deployment/hive-operator --tail=50 || true
  echo "Leader election lease status:"
  oc get lease -n hive -o yaml || true
fi

# Create HiveConfig to initialize Hive
echo "Creating HiveConfig..."
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: HiveConfig
metadata:
  name: hive
spec:
  targetNamespace: hive
  logLevel: info
  featureGates:
    enabled:
    - PreserveOnDelete
EOF

# Wait for Hive operator to create all CRDs after processing HiveConfig
echo "Waiting for Hive operator to create all required CRDs..."
RETRY_COUNT=0
MAX_RETRIES=60  # 5 minutes with 5 second intervals

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  MISSING_CRDS=""

  # Check for each required CRD
  if ! oc get crd clusterimagesets.hive.openshift.io &>/dev/null; then
    MISSING_CRDS="${MISSING_CRDS} clusterimagesets.hive.openshift.io"
  fi

  if ! oc get crd clusterdeployments.hive.openshift.io &>/dev/null; then
    MISSING_CRDS="${MISSING_CRDS} clusterdeployments.hive.openshift.io"
  fi

  if ! oc get crd machinepools.hive.openshift.io &>/dev/null; then
    MISSING_CRDS="${MISSING_CRDS} machinepools.hive.openshift.io"
  fi

  if [ -z "$MISSING_CRDS" ]; then
    echo "All required Hive CRDs are now available"
    break
  fi

  echo "Still waiting for CRDs:${MISSING_CRDS} (attempt $((RETRY_COUNT + 1))/${MAX_RETRIES})"
  sleep 5
  RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo "========================================="
  echo "ERROR: Timeout waiting for Hive CRDs to be created"
  echo "========================================="

  echo ""
  echo "=== Available Hive CRDs ==="
  oc get crds | grep hive || echo "No Hive CRDs found"

  echo ""
  echo "=== Hive Namespace Pods ==="
  oc get pods -n hive -o wide || true

  echo ""
  echo "=== Hive Operator Pod Status ==="
  oc describe pods -n hive -l app=hive-operator || true

  echo ""
  echo "=== Hive Deployments ==="
  oc get deployments -n hive || true

  echo ""
  echo "=== Recent Hive Namespace Events ==="
  oc get events -n hive --sort-by='.lastTimestamp' | tail -30 || true

  echo ""
  echo "=== Leader Election Lease Status ==="
  oc get lease -n hive -o yaml || true

  echo ""
  echo "=== HiveConfig Status ==="
  oc get hiveconfig hive -o yaml || true

  echo ""
  echo "=== Hive Operator Logs (last 100 lines) ==="
  oc logs -n hive deployment/hive-operator --tail=100 || true

  echo ""
  echo "========================================="
  exit 1
fi

# Now wait for CRDs to be fully established
echo "Waiting for Hive CRDs to be established..."
oc wait --for=condition=established --timeout=2m \
  crd/clusterimagesets.hive.openshift.io \
  crd/clusterdeployments.hive.openshift.io \
  crd/machinepools.hive.openshift.io

# Wait for Hive controllers to start
echo "Waiting for Hive controllers deployment..."
oc wait --for=condition=Available --timeout=5m deployment/hive-controllers -n hive || {
  echo "Warning: hive-controllers deployment not available yet, checking status..."
  oc get deployments -n hive
  oc get pods -n hive
}

# Verify Hive components are running
echo "Verifying Hive installation..."
oc get deployments -n hive
oc get pods -n hive

echo "Hive operator installed successfully!"
