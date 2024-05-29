#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -e

trap 'catchError' ERR

catchError() {
  if [ $? -ne 0 ]; then
    echo "An error occurred. Sleeping for 7200 seconds..."
    sleep 7200
  fi
}

echo "Deploying TektonHub"
oc apply -f - <<EOF
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonHub
metadata:
  name: hub
spec:
  targetNamespace: openshift-pipelines
  api:
    catalogRefreshInterval: 10m
EOF

echo "Creating secrets for Tekton Results"
password=$(openssl rand -base64 20 | tr -d '\n')
oc create secret -n openshift-pipelines generic tekton-results-postgres --from-literal=POSTGRES_USER=result --from-literal=POSTGRES_PASSWORD=$password
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=tekton-results-api-service.openshift-pipelines.svc.cluster.local" -addext "subjectAltName=DNS:tekton-results-api-service.openshift-pipelines.svc.cluster.local"
oc create secret tls -n openshift-pipelines tekton-results-tls --cert=cert.pem --key=key.pem

echo "Creating persistant volume claim"
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tekton-logs
  namespace: openshift-pipelines
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF

echo "Creating TektonResult"
oc apply -f - <<EOF
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonResult
metadata:
  name: result
spec:
  targetNamespace: openshift-pipelines
  logs_api: true
  log_level: debug
  db_port: 5432
  db_host: tekton-results-postgres-service.openshift-pipelines.svc.cluster.local
  logging_pvc_name: tekton-logs
  logs_path: /logs
  logs_type: File
  logs_buffer_size: 2097152
  auth_disable: true
  tls_hostname_override: tekton-results-api-service.openshift-pipelines.svc.cluster.local
  db_enable_auto_migration: true
  server_port: 8080
  prometheus_port: 9090
EOF

echo "Creating results route"
oc create route -n openshift-pipelines passthrough tekton-results-api-service --service=tekton-results-api-service --port=8080

echo "Creating signing secret for Tekton Chains"
export COSIGN_PASSWORD="chainstest"
cosign generate-key-pair k8s://openshift-pipelines/signing-secrets
publicKeyPath="testdata/chains/key"
mkdir -p $publicKeyPath
oc get secrets signing-secrets -n openshift-pipelines -o jsonpath='{.data.cosign\\.pub}' | tr -d "'" | base64 --decode > "$publicKeyPath/cosign.pub"

