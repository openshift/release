#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -e

function deploy_tektonhub() {
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
  for _ in {1..30}
  do
    if oc get tektonhub hub -n openshift-pipelines; then
      echo "TektonHub deployed successfully."
      break
    else
      echo "Waiting for TektonHub to be deployed..."
      sleep 30
    fi
  done
}

function create_tekton_results_secrets() {
  password=$(openssl rand -base64 20 | tr -d '\n')
  oc create secret -n openshift-pipelines generic tekton-results-postgres --from-literal=POSTGRES_USER=result --from-literal=POSTGRES_PASSWORD=$password
  openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=tekton-results-api-service.openshift-pipelines.svc.cluster.local" -addext "subjectAltName=DNS:tekton-results-api-service.openshift-pipelines.svc.cluster.local"
  oc create secret tls -n openshift-pipelines tekton-results-tls --cert=cert.pem --key=key.pem
}

function create_pvc() {
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
  for _ in {1..30}
  do
    if oc get pvc tekton-logs -n openshift-pipelines; then
      echo "PVC created successfully."
      break
    else
      echo "Waiting for PVC to be created..."
      sleep 30
    fi
  done
}

function deploy_tektonresult() {
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
  for _ in {1..30}
  do
    if oc get tektonresult result -n openshift-pipelines; then
      echo "TektonResult deployed successfully."
      break
    else
      echo "Waiting for TektonResult to be deployed..."
      sleep 30
    fi
  done
}

function create_results_route() {
  oc create route -n openshift-pipelines passthrough tekton-results-api-service --service=tekton-results-api-service --port=8080
  for _ in {1..30}
  do
    if oc get route tekton-results-api-service -n openshift-pipelines; then
      echo "Route created successfully."
      break
    else
      echo "Waiting for route to be created..."
      sleep 30
    fi
  done
}

function create_signing_secrets() {
  export COSIGN_PASSWORD="chainstest"
  cosign generate-key-pair k8s://openshift-pipelines/signing-secrets
  publicKeyPath="testdata/chains/key"
  mkdir -p $publicKeyPath
  oc get secrets signing-secrets -n openshift-pipelines -o jsonpath='{.data.cosign\\.pub}' | tr -d "'" | base64 --decode > "$publicKeyPath/cosign.pub"
}

deploy_tektonhub
create_tekton_results_secrets
create_pvc
deploy_tektonresult
create_results_route
create_signing_secrets
