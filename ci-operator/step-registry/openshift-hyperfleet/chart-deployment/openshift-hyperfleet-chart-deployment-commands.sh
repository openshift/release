#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}


helm plugin install https://github.com/aslafy-z/helm-git
helm plugin list 

GCP_CREDENTIALS_FILE="${HYPERFLEET_E2E_PATH}/hcm-hyperfleet-e2e.json"

# Authenticate to Google Cloud
function gcloud_auth() {
  local service_project_id="$1"
  if ! which gcloud; then
    GCLOUD_TAR="google-cloud-cli-linux-x86_64.tar.gz"
    GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GCLOUD_TAR"
    logger "INFO" "gcloud not installed, installing from $GCLOUD_URL"
    pushd ${HOME}
    curl -O "$GCLOUD_URL"
    tar -xzf "$GCLOUD_TAR"
    export PATH=${HOME}/google-cloud-sdk/bin:${PATH}
    popd
  fi

  gcloud components install gke-gcloud-auth-plugin --quiet
  export USE_GKE_GCLOUD_AUTH_PLUGIN=True
  
  gcloud auth activate-service-account --key-file="${GCP_CREDENTIALS_FILE}"
  gcloud config set project "${service_project_id}"

}

PROJECT_ID="$(jq -r -c .project_id "${GCP_CREDENTIALS_FILE}")"
gcloud_auth "$PROJECT_ID"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" \
    --zone="us-central1-a" \
    --project="$PROJECT_ID"

cd charts/hyperfleet-base
helm dependency update
cd ../hyperfleet-gcp
helm dependency update

# Generate the updated values file
cat <<EOF | envsubst > values_changed.yaml
base:
  hyperfleet-api:
    image:
      registry: $IMAGE_REGISTRY
      tag: $IMAGE_TAG
  sentinel:
    image:
      registry: $IMAGE_REGISTRY
      tag: $IMAGE_TAG
    broker:
      topic: $CLUSTER_TOPIC_NAME
      googlepubsub:
        projectId: $PROJECT_ID
    config:
      hyperfleetApi:
        baseUrl: "http://hyperfleet-api.$NAMESPACE_NAME.svc.cluster.local:8000"
  adapter-landing-zone:
    image:
      registry: $IMAGE_REGISTRY
      tag: $IMAGE_TAG
    broker:
      googlepubsub:
        projectId: $PROJECT_ID
        topic: $CLUSTER_TOPIC_NAME
        subscription: $NAMESPACE_NAME-clusters-landing-zone-adapter
        deadLetterTopic: $CLUSTER_DLQ_TOPIC_NAME
    hyperfleetApi:
      baseUrl: http://hyperfleet-api.$NAMESPACE_NAME.svc.cluster.local:8000
validation-gcp:
  image:
    registry: $IMAGE_REGISTRY
    tag: $IMAGE_TAG
  broker:
    googlepubsub:
      projectId: $PROJECT_ID
      topic: $CLUSTER_TOPIC_NAME
      subscription: ${NAMESPACE_NAME}-clusters-validation-gcp-adapter
      deadLetterTopic: $CLUSTER_DLQ_TOPIC_NAME
  hyperfleetApi:
    baseUrl: http://hyperfleet-api.$NAMESPACE_NAME.svc.cluster.local:8000
  validation:
    statusReporterImage: "registry.ci.openshift.org/ci/status-reporter:latest"
    dummy:
      simulateResult: "success"
      resultsPath: "/results/adapter-result.json"
      maxWaitTimeSeconds: "300"
EOF


if helm list -n $NAMESPACE_NAME -f $RELEASE_NAME -q | grep -q "^$RELEASE_NAME$"; then
  echo "Release $RELEASE_NAME already exists. Use 'helm upgrade' instead."
  helm upgrade $RELEASE_NAME . \
    -f ../../examples/gcp-pubsub/values.yaml \
    -f values_changed.yaml \
    -n $NAMESPACE_NAME
else
  echo "Release '$RELEASE_NAME' does not exist. Installing..."
  helm install $RELEASE_NAME . \
    -f ../../examples/gcp-pubsub/values.yaml \
    -f values_changed.yaml \
    -n $NAMESPACE_NAME --create-namespace
fi


log "=== Waiting for all pods to be Running ==="
TIMEOUT=300
PODS_READY=false

for _i in $(seq 1 $((TIMEOUT / 10))); do
  TOTAL_PODS=$(kubectl get pods -n $NAMESPACE_NAME -o json | jq -r '.items | length')
  NOT_RUNNING=$(kubectl get pods -n $NAMESPACE_NAME -o json | jq -r '.items[] | select(.status.phase != "Running") | .metadata.name' | wc -l)

  if [ "$TOTAL_PODS" -gt 0 ] && [ "$NOT_RUNNING" -eq 0 ]; then
    log "All pods are Running"
    PODS_READY=true
    break
  fi

  log "Waiting for pods to be ready... ($NOT_RUNNING/$TOTAL_PODS pods not running)"
  sleep 10
done

log "=== Deployment Configuration ==="
echo "helm get values $RELEASE_NAME -n $NAMESPACE_NAME"
helm get values $RELEASE_NAME -n $NAMESPACE_NAME > "${ARTIFACT_DIR}/values.yaml"

log "=== Checking all deployed resources ==="
kubectl get all -n $NAMESPACE_NAME > "${ARTIFACT_DIR}/all-resources.txt"

log "=== Checking pod logs for all pods ==="
for pod in $(kubectl get pods -n $NAMESPACE_NAME -o jsonpath='{.items[*].metadata.name}'); do
  log "Collecting logs for pod: $pod"
  kubectl logs "$pod" -n $NAMESPACE_NAME > "${ARTIFACT_DIR}/${pod}-logs.txt" 2>&1 || log "WARNING: Cannot retrieve logs for pod $pod"
done

if [ "$PODS_READY" != "true" ]; then
  log "ERROR: Deployment failed - not all pods are Running in $TIMEOUT seconds"
  exit 1
fi

log "SUCCESS: All pods are Running and deployment is healthy"

log "=== Exposing external IP for hyperfleet-api service ==="
kubectl patch svc hyperfleet-api -n $NAMESPACE_NAME -p '{"spec": {"type": "LoadBalancer"}}'

log "=== Waiting for EXTERNAL-IP to be assigned ==="
EXTERNAL_IP_READY=false

for _i in $(seq 1 $((TIMEOUT / 10))); do
  EXTERNAL_IP=$(kubectl get svc hyperfleet-api -n $NAMESPACE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

  if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; then
    log "EXTERNAL-IP assigned: $EXTERNAL_IP"
    log "You can access hyperfleet-api via http://$EXTERNAL_IP:8000/api/hyperfleet/v1/clusters"
    EXTERNAL_IP_READY=true
    break
  fi

  log "Waiting for EXTERNAL-IP to be assigned... (currently pending)"
  sleep 10
done

if [ "$EXTERNAL_IP_READY" != "true" ]; then
  log "ERROR: EXTERNAL-IP was not assigned within ${TIMEOUT} seconds"
  kubectl get svc hyperfleet-api -n $NAMESPACE_NAME
  exit 1
fi
