#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========== Installing Dependencies =========="

# Install oc if not available
if ! command -v oc &> /dev/null; then
    echo "oc not found, installing..."
    curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz -o /tmp/oc.tar.gz
    tar -xzf /tmp/oc.tar.gz -C /tmp oc
    chmod +x /tmp/oc
    export PATH="/tmp:${PATH}"
    echo "oc installed successfully"
else
    echo "oc is already installed"
fi

echo "========== Deploying MinIO for S3-compatible Object Storage =========="

MINIO_NAMESPACE="${MINIO_NAMESPACE:-minio}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"
MINIO_STORAGE_SIZE="${MINIO_STORAGE_SIZE:-10Gi}"

echo "MinIO Namespace: ${MINIO_NAMESPACE}"
echo "Storage Size: ${MINIO_STORAGE_SIZE}"

# Create namespace
echo "Creating namespace ${MINIO_NAMESPACE}..."
oc create namespace "${MINIO_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Deploy MinIO
echo "Deploying MinIO..."
cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: ${MINIO_NAMESPACE}
type: Opaque
stringData:
  access-key: "${MINIO_ACCESS_KEY}"
  secret-key: "${MINIO_SECRET_KEY}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: ${MINIO_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${MINIO_STORAGE_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${MINIO_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:RELEASE.2024-10-02T17-50-41Z
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: access-key
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: secret-key
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
          initialDelaySeconds: 10
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /minio/health/live
            port: 9000
          initialDelaySeconds: 10
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ${MINIO_NAMESPACE}
spec:
  ports:
  - port: 9000
    targetPort: 9000
    protocol: TCP
    name: api
  - port: 9001
    targetPort: 9001
    protocol: TCP
    name: console
  selector:
    app: minio
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: minio-api
  namespace: ${MINIO_NAMESPACE}
spec:
  to:
    kind: Service
    name: minio
  port:
    targetPort: api
EOF

# Wait for MinIO to be ready
echo "Waiting for MinIO deployment to be ready..."
oc wait --for=condition=Available deployment/minio -n "${MINIO_NAMESPACE}" --timeout=300s

echo "MinIO deployment is ready!"

# Create buckets using a Job
echo "Creating MinIO buckets..."
cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-buckets
  namespace: ${MINIO_NAMESPACE}
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: mc
        image: quay.io/minio/minio:RELEASE.2024-10-02T17-50-41Z
        command:
        - /bin/sh
        - -c
        - |
          echo "Configuring MinIO client..."
          /usr/bin/mc alias set myminio http://minio.${MINIO_NAMESPACE}.svc:9000 \${MINIO_ACCESS_KEY} \${MINIO_SECRET_KEY}
          
          echo "Creating buckets..."
          /usr/bin/mc mb --ignore-existing myminio/ros-data
          /usr/bin/mc mb --ignore-existing myminio/insights-upload-perma
          /usr/bin/mc mb --ignore-existing myminio/koku-bucket
          
          echo "Setting bucket policies..."
          /usr/bin/mc anonymous set download myminio/ros-data
          /usr/bin/mc anonymous set download myminio/insights-upload-perma
          /usr/bin/mc anonymous set download myminio/koku-bucket
          
          echo "Bucket creation completed!"
          /usr/bin/mc ls myminio/
        env:
        - name: MINIO_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: access-key
        - name: MINIO_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: secret-key
EOF

# Wait for bucket creation job to complete
echo "Waiting for bucket creation to complete..."
oc wait --for=condition=Complete job/minio-create-buckets -n "${MINIO_NAMESPACE}" --timeout=120s

echo "========== MinIO Deployment Complete =========="
echo "MinIO API endpoint: http://minio.${MINIO_NAMESPACE}.svc:9000"
echo "MinIO Console endpoint: http://minio.${MINIO_NAMESPACE}.svc:9001"
echo "Buckets created: ros-data, insights-upload-perma, koku-bucket"

# Save MinIO configuration to SHARED_DIR for use by other steps
echo "${MINIO_NAMESPACE}" > "${SHARED_DIR}/minio-namespace"
echo "minio.${MINIO_NAMESPACE}.svc:9000" > "${SHARED_DIR}/minio-endpoint"
echo "${MINIO_ACCESS_KEY}" > "${SHARED_DIR}/minio-access-key"
echo "${MINIO_SECRET_KEY}" > "${SHARED_DIR}/minio-secret-key"

echo "MinIO configuration saved to SHARED_DIR"

