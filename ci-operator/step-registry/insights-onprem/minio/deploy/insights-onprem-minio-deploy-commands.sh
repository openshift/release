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

# MinIO goes in its own namespace (like ODF uses openshift-storage)
MINIO_NAMESPACE="${MINIO_NAMESPACE:-minio}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"
MINIO_STORAGE_SIZE="${MINIO_STORAGE_SIZE:-10Gi}"

echo "MinIO Namespace: ${MINIO_NAMESPACE}"
echo "Storage Size: ${MINIO_STORAGE_SIZE}"

# Create MinIO namespace
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
# Note: minio-endpoint is just the hostname (no protocol or port)
echo "${MINIO_NAMESPACE}" > "${SHARED_DIR}/minio-namespace"
echo "minio.${MINIO_NAMESPACE}.svc" > "${SHARED_DIR}/minio-endpoint"
echo "${MINIO_ACCESS_KEY}" > "${SHARED_DIR}/minio-access-key"
echo "${MINIO_SECRET_KEY}" > "${SHARED_DIR}/minio-secret-key"

echo "MinIO configuration saved to SHARED_DIR"

echo "========== Creating ODF Credentials Secret in Application Namespace =========="

# The ODF credentials secret goes in the APPLICATION namespace (where helm chart deploys)
# This is separate from the MinIO namespace (storage layer)
APP_NAMESPACE="${APP_NAMESPACE:-cost-onprem}"
SECRET_NAME="${ODF_CREDENTIALS_SECRET_NAME:-cost-onprem-odf-credentials}"

# Create application namespace if it doesn't exist
echo "Creating application namespace ${APP_NAMESPACE}..."
oc create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Apply cost management optimization label (required by the operator)
echo "Applying cost management optimization label to namespace..."
oc label namespace "${APP_NAMESPACE}" cost_management_optimizations=true --overwrite

echo "Creating ${SECRET_NAME} secret in namespace: ${APP_NAMESPACE}"
oc create secret generic "${SECRET_NAME}" \
    --namespace="${APP_NAMESPACE}" \
    --from-literal=access-key="${MINIO_ACCESS_KEY}" \
    --from-literal=secret-key="${MINIO_SECRET_KEY}" \
    --dry-run=client -o yaml | oc apply -f -

echo "========== Creating MinIO Proxy Service in Application Namespace =========="
# Create a service that listens on port 9000 and forwards to MinIO's ClusterIP:9000
# This allows the chart to use just the hostname for odf.endpoint while the
# MinIO client connects on port 9000 (which we'll set via odf.port)
#
# WORKAROUND: The chart has a bug where STORAGE_ENDPOINT doesn't include the port.
# The MinIO client defaults to port 80 for HTTP. To work around this, we create
# a service that listens on BOTH port 80 and 9000, forwarding to MinIO on 9000.
# This way:
# - TCP check uses /dev/tcp/minio-storage/9000 (works)
# - MinIO client uses minio-storage:80 (which forwards to MinIO:9000)

MINIO_CLUSTER_IP=$(oc get svc minio -n "${MINIO_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
echo "MinIO ClusterIP: ${MINIO_CLUSTER_IP}"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: minio-storage
  namespace: ${APP_NAMESPACE}
spec:
  ports:
  - port: 80
    targetPort: 9000
    protocol: TCP
    name: http
  - port: 9000
    targetPort: 9000
    protocol: TCP
    name: api
---
apiVersion: v1
kind: Endpoints
metadata:
  name: minio-storage
  namespace: ${APP_NAMESPACE}
subsets:
- addresses:
  - ip: ${MINIO_CLUSTER_IP}
  ports:
  - port: 9000
    name: http
  - port: 9000
    name: api
EOF

echo "MinIO proxy service created:"
echo "  minio-storage:80 -> ${MINIO_CLUSTER_IP}:9000 (for MinIO client default port)"
echo "  minio-storage:9000 -> ${MINIO_CLUSTER_IP}:9000 (for TCP check)"

# Save namespace info for the e2e tests
# MINIO_HOST is just the hostname (for odf.endpoint - chart uses this for STORAGE_ENDPOINT)
# MINIO_PORT is 9000 (for odf.port - chart uses this for TCP check)
echo "MINIO_NAMESPACE=${MINIO_NAMESPACE}" >> "${SHARED_DIR}/minio-env"
echo "APP_NAMESPACE=${APP_NAMESPACE}" >> "${SHARED_DIR}/minio-env"
echo "MINIO_HOST=minio-storage" >> "${SHARED_DIR}/minio-env"
echo "MINIO_PORT=9000" >> "${SHARED_DIR}/minio-env"
echo "MINIO_ENDPOINT=minio-storage:9000" >> "${SHARED_DIR}/minio-env"
echo "S3_ENDPOINT=http://minio.${MINIO_NAMESPACE}.svc:9000" >> "${SHARED_DIR}/minio-env"

# minio-endpoint file - just the hostname for chart compatibility
echo "minio-storage" > "${SHARED_DIR}/minio-endpoint"

echo "ODF credentials secret created successfully in ${APP_NAMESPACE} namespace"
echo "MinIO is accessible from ${APP_NAMESPACE} at: http://minio-proxy.${APP_NAMESPACE}.svc:9000"

