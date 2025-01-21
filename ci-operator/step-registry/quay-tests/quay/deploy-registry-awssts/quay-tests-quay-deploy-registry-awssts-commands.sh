#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Get the credentials and Email of new Quay User
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

# env variables from shared dir for aws sts
QUAY_AWS_STS_S3_BUCKET=$([ -f "${SHARED_DIR}/QUAY_AWS_STS_S3_BUCKET" ] && cat "${SHARED_DIR}/QUAY_AWS_STS_S3_BUCKET" || echo "")
QUAY_AWS_STS_ROLE_ARN=$([ -f "${SHARED_DIR}/QUAY_AWS_STS_ROLE_ARN" ] && cat "${SHARED_DIR}/QUAY_AWS_STS_ROLE_ARN" || echo "") 
QUAY_AWS_STS_ACCESSKEY=$([ -f "${SHARED_DIR}/QUAY_AWS_STS_ACCESSKEY" ] && cat "${SHARED_DIR}/QUAY_AWS_STS_ACCESSKEY" || echo "")
QUAY_AWS_STS_SECRETKEY=$([ -f "${SHARED_DIR}/QUAY_AWS_STS_SECRETKEY" ] && cat "${SHARED_DIR}/QUAY_AWS_STS_SECRETKEY" || echo "")

echo "Create registry ${QUAYREGISTRY} in ns ${QUAYNAMESPACE}"

#create secret bundle with aws sts s3
cat >>config.yaml <<EOF
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_AUTO_PRUNE: true
FEATURE_PROXY_CACHE: true
FEATURE_USER_INITIALIZE: true
PERMANENTLY_DELETE_TAGS: true
RESET_CHILD_MANIFEST_EXPIRATION: true
FEATURE_PROXY_STORAGE: true
IGNORE_UNKNOWN_MEDIATYPES: true
FEATURE_UI_V2: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
SUPER_USERS:
  - quay
FEATURE_ANONYMOUS_ACCESS: true
BROWSER_API_CALLS_XHR_ONLY: false
FEATURE_USERNAME_CONFIRMATION: false
AUTHENTICATION_TYPE: Database
FEATURE_LISTEN_IP_VERSION: IPv4
REPO_MIRROR_ROLLBACK: false
AUTOPRUNE_TASK_RUN_MINIMUM_INTERVAL_MINUTES: 1
DEFAULT_TAG_EXPIRATION: 2w
TAG_EXPIRATION_OPTIONS:
  - 2w
  - 1d
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - STSS3Storage
    - s3_bucket: ${QUAY_AWS_STS_S3_BUCKET}
      storage_path: /datafile
      sts_user_access_key: ${QUAY_AWS_STS_ACCESSKEY}
      sts_user_secret_key: ${QUAY_AWS_STS_SECRETKEY}
      sts_role_arn: ${QUAY_AWS_STS_ROLE_ARN}
      s3_region: us-east-2
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
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
  - kind: objectstorage
    managed: false
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
