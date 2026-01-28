#!/bin/bash
set -euxo pipefail

# This script assumes that the acm-install chain has already completed and the MultiClusterHub is available.

# Step 1: Create namespace for MCO
echo "[INFO] Creating namespace open-cluster-management-observability..."
if ! oc get ns open-cluster-management-observability >/dev/null 2>&1; then
  oc create ns open-cluster-management-observability
fi

# Step 2: Deploy MinIO and create the MultiClusterObservability CR
echo "[INFO] Deploying MinIO and creating MultiClusterObservability resource..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio
  namespace: open-cluster-management-observability
spec:
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: "1Gi"}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: open-cluster-management-observability
spec:
  replicas: 1
  selector: {matchLabels: {app: minio}}
  template:
    metadata:
      labels: {app: minio}
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:RELEASE.2021-08-25T00-41-18Z
        command: ["/bin/sh", "-c", "mkdir -p /storage/thanos && /usr/bin/minio server /storage"]
        env:
        - {name: MINIO_ACCESS_KEY, value: minio}
        - {name: MINIO_SECRET_KEY, value: minio123}
        ports:
        - {containerPort: 9000}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: open-cluster-management-observability
spec:
  ports:
  - {port: 9000, targetPort: 9000}
  selector: {app: minio}
---
apiVersion: v1
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: open-cluster-management-observability
stringData:
  thanos.yaml: |
    type: s3
    config:
      bucket: "thanos"
      endpoint: "minio.open-cluster-management-observability.svc.cluster.local:9000"
      insecure: true
      access_key: "minio"
      secret_key: "minio123"
---
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  observabilityAddonSpec:
    enabled: true
  storageConfig:
    metricObjectStorage:
      name: thanos-object-storage
      key: thanos.yaml
EOF

# Step 3: Wait for MinIO and MCO components to be ready
echo "[INFO] Waiting for MinIO and MCO components to become ready..."
oc wait --for=condition=Available --timeout=10m Deployment/minio -n open-cluster-management-observability
oc wait --for=condition=Ready pod -l alertmanager=observability,app=multicluster-observability-alertmanager -n open-cluster-management-observability --timeout=5m
oc wait --for=condition=Ready pod -l app=rbac-query-proxy -n open-cluster-management-observability --timeout=5m
echo "[SUCCESS] ACM Observability is fully ready."
