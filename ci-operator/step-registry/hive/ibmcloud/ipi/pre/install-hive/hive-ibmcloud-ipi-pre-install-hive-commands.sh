#!/bin/bash

set -euo pipefail

echo "[INFO] Installing Hive operator from HIVE_IMAGE: ${HIVE_IMAGE}"

# Create hive namespace
echo "[INFO] Creating hive namespace"
oc create namespace hive || true

# Extract Hive operator deployment manifests from the built image
echo "[INFO] Extracting Hive operator manifests from image"
mkdir -p /tmp/hive-deploy

# Extract the operator deployment files
# Try multiple common paths where Hive stores its deployment manifests
if oc image extract "${HIVE_IMAGE}" --path /opt/hive/:/tmp/hive-deploy --confirm 2>/dev/null; then
  echo "[INFO] Extracted from /opt/hive/"
elif oc image extract "${HIVE_IMAGE}" --path /:/tmp/hive-deploy --confirm 2>/dev/null; then
  echo "[INFO] Extracted from root"
else
  echo "[WARN] Could not extract manifests, will use simplified deployment"
fi

# Apply CRDs if found, otherwise create basic ones
if [ -d "/tmp/hive-deploy/config/crds" ]; then
  echo "[INFO] Applying Hive CRDs from extracted config"
  oc apply -f /tmp/hive-deploy/config/crds/
elif [ -f "/tmp/hive-deploy/crds.yaml" ]; then
  echo "[INFO] Applying Hive CRDs from crds.yaml"
  oc apply -f /tmp/hive-deploy/crds.yaml
else
  echo "[INFO] Creating essential Hive CRDs"
  # Create essential CRDs for Hive to function
  # In production, these would come from the built image
  oc apply -f - <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: hiveconfigs.hive.openshift.io
spec:
  group: hive.openshift.io
  scope: Cluster
  names:
    plural: hiveconfigs
    singular: hiveconfig
    kind: HiveConfig
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
  name: clusterdeployments.hive.openshift.io
spec:
  group: hive.openshift.io
  scope: Namespaced
  names:
    plural: clusterdeployments
    singular: clusterdeployment
    kind: ClusterDeployment
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: clusterimagesets.hive.openshift.io
spec:
  group: hive.openshift.io
  scope: Cluster
  names:
    plural: clusterimagesets
    singular: clusterimageset
    kind: ClusterImageSet
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
EOF
fi

# Create ServiceAccount for Hive operator
echo "[INFO] Creating Hive operator ServiceAccount and RBAC"
oc -n hive create serviceaccount hive-operator || true

# Create ClusterRole with necessary permissions
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hive-operator
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
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
EOF

# Deploy Hive operator Deployment
echo "[INFO] Deploying Hive operator"
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hive-operator
  namespace: hive
  labels:
    control-plane: hive-operator
    hive.openshift.io/operator: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      control-plane: hive-operator
  template:
    metadata:
      labels:
        control-plane: hive-operator
    spec:
      serviceAccountName: hive-operator
      containers:
      - name: hive-operator
        image: ${HIVE_IMAGE}
        command:
        - /opt/services/hive-operator
        - --log-level=info
        env:
        - name: CLI_CACHE_DIR
          value: /var/cache/kubectl
        - name: HIVE_OPERATOR_NS
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        resources:
          requests:
            cpu: 10m
            memory: 256Mi
        volumeMounts:
        - name: kubectl-cache
          mountPath: /var/cache/kubectl
      volumes:
      - name: kubectl-cache
        emptyDir: {}
EOF

echo "[INFO] Waiting for Hive operator to be ready"
oc -n hive wait --for=condition=Available deployment/hive-operator --timeout=10m

echo "[INFO] Hive operator is running, creating HiveConfig"

# Create HiveConfig CR - this triggers the operator to deploy all other controllers
oc apply -f - <<EOF
apiVersion: hive.openshift.io/v1
kind: HiveConfig
metadata:
  name: hive
spec:
  managedDomains: []
  targetNamespace: hive
  logLevel: info
  featureGates:
    custom:
      enabled:
      - ClusterDeploymentTemplates
EOF

echo "[INFO] HiveConfig created, waiting for controllers to be provisioned"

# Wait for hive-controllers deployment to be created by the operator
echo "[INFO] Waiting for hive-controllers deployment..."
for i in {1..60}; do
  if oc -n hive get deployment hive-controllers 2>/dev/null; then
    echo "[SUCCESS] hive-controllers deployment created"
    break
  fi
  if [ $i -eq 60 ]; then
    echo "[ERROR] hive-controllers deployment was not created within timeout"
    echo "[DEBUG] HiveConfig status:"
    oc get hiveconfig hive -o yaml
    echo "[DEBUG] Hive operator logs:"
    oc -n hive logs deployment/hive-operator --tail=50
    exit 1
  fi
  echo "[INFO] Waiting for hive-controllers deployment to be created... ($i/60)"
  sleep 5
done

# Wait for hive-controllers to be ready
echo "[INFO] Waiting for hive-controllers to be available..."
oc -n hive wait --for=condition=Available deployment/hive-controllers --timeout=15m

# Wait for HiveConfig to report ready status
echo "[INFO] Waiting for HiveConfig to be ready..."
for i in {1..60}; do
  STATUS=$(oc get hiveconfig hive -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "${STATUS}" = "True" ]; then
    echo "[SUCCESS] HiveConfig is ready"
    break
  fi
  if [ $i -eq 60 ]; then
    echo "[WARN] HiveConfig did not report ready within timeout, but continuing"
    oc get hiveconfig hive -o yaml
  fi
  echo "[INFO] Waiting for HiveConfig Ready condition... ($i/60)"
  sleep 5
done

# Display final status
echo "[INFO] Hive deployment status:"
oc -n hive get deployments
oc -n hive get pods

echo "[SUCCESS] Hive operator and controllers are running"
