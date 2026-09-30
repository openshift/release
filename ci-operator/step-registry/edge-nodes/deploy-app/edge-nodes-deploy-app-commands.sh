#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
edge_app_manifest="${ARTIFACT_DIR}"/edge-app.yaml

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $1"
}

function print_debug_info()
{
    echo_date "machine info:"
    oc get machineset -n openshift-machine-api

    echo_date "machine info:"
    oc get machine -n openshift-machine-api

    echo_date "node info:"
    oc get nodes

    echo_date "app info:"
    oc get all -n edge-app || true
}

trap 'print_debug_info' EXIT TERM INT

REPLICA_COUNT=$(wc -l "${SHARED_DIR}"/edge-zone-names.txt | awk '{print$1}')

cat << EOF > "${edge_app_manifest}"
kind: Namespace
apiVersion: v1
metadata:
  name: edge-app
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app
  namespace: edge-app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: edge-app-image-puller
  namespace: openshift
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:image-puller
subjects:
  - kind: ServiceAccount
    name: app
    namespace: edge-app
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: edge-app
  namespace: edge-app
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp2-csi 
  volumeMode: Filesystem
---
apiVersion: apps/v1
kind: Deployment 
metadata:
  name: edge-app
  namespace: edge-app
spec:
  selector:
    matchLabels:
      app: edge-app
  replicas: ${REPLICA_COUNT}
  template:
    metadata:
      labels:
        app: edge-app
    spec:
      serviceAccountName: app
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      nodeSelector: 
        node-role.kubernetes.io/edge: ""
      tolerations: 
      - key: "node-role.kubernetes.io/edge"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
      containers:
        - image: "image-registry.openshift-image-registry.svc:5000/openshift/tests:latest"
          command:
           - "/bin/socat"
          args:
            - TCP4-LISTEN:8080,reuseaddr,fork
            - EXEC:'/bin/bash -c \"printf \\\"HTTP/1.0 200 OK\r\n\r\n\\\"; sed -e \\\"/^\r/q\\\"\"'
          imagePullPolicy: Always
          name: echoserver
          ports:
            - containerPort: 8080
          volumeMounts:
            - mountPath: "/mnt/storage"
              name: data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: edge-app
EOF

echo "Deploying sample app"
oc create -f "${edge_app_manifest}"

echo_date "Waiting app to be ready..."
retry_count=0
max_retries=3

until oc wait deployment -n edge-app edge-app --for=condition=Available --timeout=5m;
do
    retry_count=$((retry_count + 1))
    echo_date "Deployment not ready yet (attempt ${retry_count}/${max_retries})"

    echo_date "Deployment status:"
    oc get deployment/edge-app -n edge-app -o wide || true

    echo_date "Pod status:"
    oc get pods -n edge-app -o wide || true

    echo_date "Recent events:"
    oc get events -n edge-app --sort-by='.lastTimestamp' | tail -10 || true

    if [ ${retry_count} -ge ${max_retries} ]; then
        echo "ERROR: Deployment failed to become ready after ${max_retries} attempts"
        echo "Final deployment status:"
        oc describe deployment/edge-app -n edge-app || true
        exit 1
    fi

    echo_date "Waiting 30 seconds before retry..."
    sleep 30
done

echo_date "Done, app deployed"
oc get all -n edge-app
