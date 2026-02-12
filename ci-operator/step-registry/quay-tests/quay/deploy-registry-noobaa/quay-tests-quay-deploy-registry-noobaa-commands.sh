#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Get the credentials and Email of new Quay User
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

echo "Create registry ${QUAYREGISTRY} with noobaa in ns ${QUAYNAMESPACE}"

#create secret bundle with aws sts s3

cat >>config.yaml <<EOF
BROWSER_API_CALLS_XHR_ONLY: false
PERMANENTLY_DELETE_TAGS: true
RESET_CHILD_MANIFEST_EXPIRATION: true
CREATE_REPOSITORY_ON_PUSH_PUBLIC: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_PROXY_CACHE: true
FEATURE_USER_INITIALIZE: true
FEATURE_GENERAL_OCI_SUPPORT: true
FEATURE_HELM_OCI_SUPPORT: true
FEATURE_PROXY_STORAGE: true
SUPER_USERS:
  - quay
FEATURE_UI_V2: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
FEATURE_AUTO_PRUNE: true
TAG_EXPIRATION_OPTIONS:
  - 1w
  - 2w
  - 4w
  - 1d
  - 1h
FEATURE_SUPERUSER_CONFIGDUMP: true
FEATURE_IMAGE_PULL_STATS: true
REDIS_FLUSH_INTERVAL_SECONDS: 30
PULL_METRICS_REDIS:
  host: quay-quay-redis
  port: 6379
  db: 1
EOF

oc create secret generic -n "${QUAYNAMESPACE}" --from-file config.yaml=./config.yaml config-bundle-secret

#Deploy Quay registry, here disable monitoring component
echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: ${QUAYREGISTRY}
  namespace: ${QUAYNAMESPACE}
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: postgres
    managed: true
  - kind: objectstorage
    managed: true
  - kind: monitoring
    managed: false
  - kind: horizontalpodautoscaler
    managed: true
  - kind: quay
    managed: true
  - kind: mirror
    managed: true
  - kind: clair
    managed: true
  - kind: tls
    managed: true
  - kind: route
    managed: true
EOF

sleep 300  # wait for pods to be ready

for i in {1..60}; do
  if [[ "$(oc -n ${QUAYNAMESPACE} get quayregistry ${QUAYREGISTRY} -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    echo "Quay is in ready status" >&2
    oc -n ${QUAYNAMESPACE} get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
    oc get quayregistry ${QUAYREGISTRY} -n ${QUAYNAMESPACE} -o jsonpath='{.status.registryEndpoint}' >"$SHARED_DIR"/quayroute || true
    quay_route=$(oc get quayregistry ${QUAYREGISTRY} -n ${QUAYNAMESPACE} -o jsonpath='{.status.registryEndpoint}') || true
    echo "Quay Route is $quay_route"
    curl -k $quay_route/api/v1/discovery | jq > "$SHARED_DIR"/quay_api_discovery
    cp "$SHARED_DIR"/quay_api_discovery "$ARTIFACT_DIR"/quay_api_discovery || true

    curl -k -X POST $quay_route/api/v1/user/initialize --header 'Content-Type: application/json' \
      --data '{ "username": "'$QUAY_USERNAME'", "password": "'$QUAY_PASSWORD'", "email": "'$QUAY_EMAIL'", "access_token": true }' | jq '.access_token' | tr -d '"' | tr -d '\n' >"$SHARED_DIR"/quay_oauth2_token || true
    
    exit 0
  fi
  sleep 15
  echo "Wait for quay registry ready $((i*15+300))s"
done
echo "Timed out waiting for Quay to become ready afer 20 mins" >&2
