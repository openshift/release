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
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/name: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: minio
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: minio
    spec:
      containers:
      - command:
        - /bin/sh
        - -c
        - mkdir -p /storage/thanos && /usr/bin/minio server /storage
        env:
        - name: MINIO_ACCESS_KEY
          value: minio
        - name: MINIO_SECRET_KEY
          value: minio123
        image:  quay.io/minio/minio:RELEASE.2021-08-25T00-41-18Z
        name: minio
        ports:
        - containerPort: 9000
          protocol: TCP
        volumeMounts:
        - mountPath: /storage
          name: storage
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: minio
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  labels:
    app.kubernetes.io/name: minio
  name: minio
  namespace: open-cluster-management-observability
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: "1Gi"
---
apiVersion: v1
stringData:
  thanos.yaml: |
    type: s3
    config:
      bucket: "thanos"
      endpoint: "minio:9000"
      insecure: true
      access_key: "minio"
      secret_key: "minio123"
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: open-cluster-management-observability
type: Opaque
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: open-cluster-management-observability
spec:
  ports:
  - port: 9000
    protocol: TCP
    targetPort: 9000
  selector:
    app.kubernetes.io/name: minio
  type: ClusterIP
EOF

echo "[INFO] Waiting for MinIO become ready..."
oc wait --for=condition=Available --timeout=20m Deployment/minio -n open-cluster-management-observability

oc apply -f - <<EOF
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  observabilityAddonSpec: {}
  storageConfig:
    metricObjectStorage:
      name: thanos-object-storage
      key: thanos.yaml
EOF

echo "[INFO] Waiting for MCO components to become ready..."
sleep 1m
oc wait --for=condition=Ready pod -l alertmanager=observability,app=multicluster-observability-alertmanager -n open-cluster-management-observability --timeout=10m
oc wait --for=condition=Ready pod -l app=rbac-query-proxy -n open-cluster-management-observability --timeout=10m
echo "[SUCCESS] ACM Observability is fully ready."
