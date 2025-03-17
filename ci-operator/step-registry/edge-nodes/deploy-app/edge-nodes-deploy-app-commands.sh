#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
edge_app_manifest="${ARTIFACT_DIR}"/edge-app.yaml

function print_debug_info()
{
    echo "machine info:"
    oc get machineset -n openshift-machine-api

    echo "machine info:"
    oc get machine -n openshift-machine-api

    echo "node info:"
    oc get nodes

    echo "app info:"
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
        - image: openshift/origin-node
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

echo "Waiting app to be ready..."
until oc wait deployment -n edge-app edge-app --for=condition=Available --timeout=5m;
do
    echo "Waiting for deployment be ready"
    oc get deployment/edge-app -l node-role.kubernetes.io/edge
    sleep 30
done

echo "Done, app deployed"
oc get all -n edge-app
