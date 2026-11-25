#!/bin/bash
set -euxo pipefail

# This script assumes that the acm-install chain has already completed and the MultiClusterHub is available.

# Step 1: Create namespace for MCO
echo "[INFO] Creating namespace open-cluster-management-observability..."
if ! oc get ns open-cluster-management-observability >/dev/null 2>&1; then
  oc create ns open-cluster-management-observability
fi

# Step 2: Deploy SeaweedFS and create the MultiClusterObservability CR
echo "[INFO] Deploying SeaweedFS and creating MultiClusterObservability resource..."
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seaweedfs
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/name: seaweedfs
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: seaweedfs
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: seaweedfs
    spec:
      containers:
      - args:
        - mini
        - -dir=/data
        - -webdav=false
        - -s3.port.iceberg=0
        env:
        - name: AWS_ACCESS_KEY_ID
          value: thanos
        - name: AWS_SECRET_ACCESS_KEY
          value: supersecret
        - name: S3_BUCKET
          value: thanos
        image: chrislusf/seaweedfs:4.29
        name: seaweedfs
        ports:
        - containerPort: 8333
          protocol: TCP
        volumeMounts:
        - mountPath: /data
          name: storage
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: seaweedfs
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  labels:
    app.kubernetes.io/name: seaweedfs
  name: seaweedfs
  namespace: open-cluster-management-observability
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: "2Gi"
---
apiVersion: v1
stringData:
  thanos.yaml: |
    type: s3
    config:
      bucket: "thanos"
      endpoint: "seaweedfs:8333"
      insecure: true
      access_key: "thanos"
      secret_key: "supersecret"
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: open-cluster-management-observability
type: Opaque
---
apiVersion: v1
kind: Service
metadata:
  name: seaweedfs
  namespace: open-cluster-management-observability
spec:
  ports:
  - port: 8333
    protocol: TCP
    targetPort: 8333
  selector:
    app.kubernetes.io/name: seaweedfs
  type: ClusterIP
EOF

echo "[INFO] Waiting for SeaweedFS become ready..."
oc wait --for=condition=Available --timeout=20m Deployment/seaweedfs -n open-cluster-management-observability

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
