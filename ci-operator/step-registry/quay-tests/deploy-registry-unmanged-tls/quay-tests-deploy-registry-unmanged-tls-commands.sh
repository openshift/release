#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "registry current folder... ${QUAYNAMESPACE},${QUAYREGISTRY} "
pwd
ls -l

#create secret bundle with odf/noobaa
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
EOF

# if env variable TLS is set and equals false, by default it is true
if [[ "$TLS" == "true" ]]; then
  oc create secret generic -n "${QUAYNAMESPACE}" --from-file config.yaml=./config.yaml config-bundle-secret
  tls=true
  echo "$TLS"
  echo  "$("$TLS" | tr -d \")"
elif [[ "$TLS" = "false" ]]; then
  oc create secret generic -n "${QUAYNAMESPACE}" --from-file config.yaml=./config.yaml --from-file ssl.cert="$SHARED_DIR"/ssl.cert \
    --from-file ssl.key="$SHARED_DIR"/ssl.key --from-file extra_ca_cert_build_cluster.crt="$SHARED_DIR"/build_cluster.crt \
    config-bundle-secret
   echo "tls false..." 
   echo "$TLS"
   tls=false
   echo  "$("$TLS" | tr -d \")"
fi

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
    managed: $TLS
  - kind: route
    managed: true
EOF

for i in {1..60}; do
  if [[ "$(oc -n ${QUAYNAMESPACE} get quayregistry ${QUAYREGISTRY} -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    echo "Quay is in ready status" >&2
    oc -n ${QUAYNAMESPACE} get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
    oc get quayregistry ${QUAYREGISTRY} -n ${QUAYNAMESPACE} -o jsonpath='{.status.registryEndpoint}' >"$SHARED_DIR"/quayroute || true
    quay_route=$(oc get quayregistry ${QUAYREGISTRY} -n ${QUAYNAMESPACE} -o jsonpath='{.status.registryEndpoint}') || true
    curl -k -X POST $quay_route/api/v1/user/initialize --header 'Content-Type: application/json' \
      --data '{ "username": "'$QUAY_USERNAME'", "password": "'$QUAY_PASSWORD'", "email": "'$QUAY_EMAIL'", "access_token": true }' | jq '.access_token' | tr -d '"' | tr -d '\n' >"$SHARED_DIR"/quay_oauth2_token || true
    exit 0
  fi
  sleep 15
  echo "wait for quay registry ready $((i*10))s"
done
echo "Timed out waiting for Quay to become ready afer 15 mins" >&2
