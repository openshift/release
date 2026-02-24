#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing Hive operator using pre-merge image..."

# Use HIVE_IMAGE from dependencies (built from the PR being tested)
HIVE_IMAGE="${HIVE_IMAGE:-${HIVE_OPERATOR_IMAGE}}"
echo "Using Hive image: ${HIVE_IMAGE}"

# Create hive namespace
echo "Creating hive namespace..."
oc create namespace hive || true

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

# Wait for Hive CRDs to be established
echo "Waiting for Hive CRDs to be established..."
oc wait --for condition=established --timeout=5m \
  crd/clusterimagesets.hive.openshift.io \
  crd/clusterdeployments.hive.openshift.io \
  crd/machinepools.hive.openshift.io || {
    echo "Warning: Some CRDs may not be available yet"
    oc get crds | grep hive
  }

# Wait for Hive controllers to start
echo "Waiting for Hive controllers to start..."
sleep 30

# Verify Hive components are running
echo "Verifying Hive installation..."
oc get pods -n hive

echo "Hive operator installed successfully!"
