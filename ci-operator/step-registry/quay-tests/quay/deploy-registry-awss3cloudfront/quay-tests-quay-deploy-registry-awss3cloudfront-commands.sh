#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# !!storage_path in config.yaml must match origin_path in cloudfront aws_cloudfront_distribution 

#Get the credentials and Email of new Quay User
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)

# env variables from shared dir for aws cloudfront
QUAY_AWS_S3_CF_BUCKET=$([ -f "${SHARED_DIR}/QUAY_AWS_S3_CF_BUCKET" ] && cat "${SHARED_DIR}/QUAY_AWS_S3_CF_BUCKET" || echo "")
QUAY_S3_CLOUDFRONT_ID=$([ -f "${SHARED_DIR}/QUAY_S3_CLOUDFRONT_ID" ] && cat "${SHARED_DIR}/QUAY_S3_CLOUDFRONT_ID" || echo "") 
QUAY_CLOUDFRONT_DOMAIN=$([ -f "${SHARED_DIR}/QUAY_CLOUDFRONT_DOMAIN" ] && cat "${SHARED_DIR}/QUAY_CLOUDFRONT_DOMAIN" || echo "")

echo "Create registry ${QUAYREGISTRY} in ns ${QUAYNAMESPACE}"

#create secret bundle with aws s3 cloudfront
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
FEATURE_UI_V2: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
SUPER_USERS:
  - quay
FEATURE_ANONYMOUS_ACCESS: true
BROWSER_API_CALLS_XHR_ONLY: false
AUTHENTICATION_TYPE: Database
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
    - CloudFrontedS3Storage
    - s3_bucket: ${QUAY_AWS_S3_CF_BUCKET}
      storage_path: /cloudfronts3/quayregistry
      cloudfront_distribution_domain: ${QUAY_CLOUDFRONT_DOMAIN}
      cloudfront_key_id: ${QUAY_S3_CLOUDFRONT_ID}
      cloudfront_privatekey_filename: default-cloudfront-signing-key.pem
      s3_access_key: ${QUAY_AWS_ACCESS_KEY}
      s3_secret_key: ${QUAY_AWS_SECRET_KEY}
      s3_region: us-east-2
      host: s3.us-east-2.amazonaws.com
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
EOF

cat >>default-cloudfront-signing-key.pem <<EOF
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCTTnzfGYxf4lWo
UuQKJ3grLdlvbvF8mGM09ltvQ/uzoTH9kUP8ehNwsu/d5lISsLbNvLzGoC101k1e
H+PXRYwaROfFadX6V42yaCtPBBOq91qXxPQ1ZR4LtqS5Td8qKIqh02LNqH0s1ibq
grU54eZw35ZkIvdh6ZyG9UhI7S0E0rXnAbTen9NxVqfeqaGUFM9emolgFiwOojpU
ELZ4IA3pbOZMU9MZCgPvaig2P7DaQqiLUKQ9i3TzOCqjZhxbCtABT+/2CdtJEDte
iTOjb0TDVLKWc7lKThxg7/aF/NGlcm19FPZ+qXhKp4vwseg4zj5yVCkRBEEG6Fwm
dbYEsI/ZAgMBAAECggEAEMf+PcRBU6MLMxPOWsHIVNLyVFmFNTZ/BseR/wj1oa8Z
bNOhtR+LG2mnHdZhPzPWf3Wi49XXl9naEoD7iciof02eQcUe1VgoEkz/sg661t06
+tM7JuIQHDGAboPKipj3whu8w8UQDY2P/WNKlf+AKxetoFbDa+obJNzIkVZDrKrP
yfXqeR8+vszI3sY5bs1GhWw+dL11rzj66wD1VTXcHIWKp9cDrTxBgx9sgoi3nNhJ
j9+BmBNKJEzTqSgsN8w8G9cc3VUyXmzfuoDq4B1WXqjw7F4efp4My9gF4yEeQGcI
80JnEVKTrFiR5mQB+gUc8HmPyIvi55NA/Su1CIEsiQKBgQDgx5nOrjAblQojK6rx
0f4OQstVD6T5pOpH+4n7/vB7hqIfSk0B2vVngMOHOJCnBWZ2VFJaAThXyg2zYnIi
0PSNfcdHrAJPO2DoE8W/uuzClG8Uhl9kGOLOSRSKg4T3w8jww4x0PUZhzruUA4/x
5Fz52PE4yahzk9vkhDMgJGWuzwKBgQCnxDU0mzinrLjh17cEEsfGtUJ8xFdUITWT
b13pyT5W2PaO3TY4lI8iLgTMZuiAWTfe0arq/ureW5sSTuFGR1hwu4URMpLoKoNu
Mh87FzQtJamgWX2ATZX6+xhT983eWwAN5LDSOeyeyNuAXNlB5r/kvevPfrZGcEzX
oLo/DLlA1wKBgFUbfiMBVPm8jqAOcqUo61ae97n3OHHFfWdP2EjvmEJNEaljSpD/
RJex61aRlkOHCeqXtq6Zc6nZuSJIjgqcr1u7We7LM/yn8OMuSVt0/RwXc4+D6S5P
NeEBTqO7dGcTXEu83rtMUA/MZL2AM8pUutdmyr7Dq+JHA6UcYPc0kMOFAoGBAIEe
ufRrIweqIAFyDSHNcoS1LR7p3myZwqpepGEyyg/9nIYIK5sQe7lKwdavvXJLOHz9
0hZbbFkHGCrXGvsEHkVljdzWl8qoLc+6M98+1KGKwyrutXDyReSNLQQzTPc+AqSu
xoiGnF75KDd7PptCBZ7/rWZdl9xOwlWTFsU//bSxAoGAAzoQPGMsq1JWkP3KaGxj
GDkpEPpG/CbKSLrynT2f1cp9fHWQASJUEl89j7BLinTz9Akl1S1mmkvSXCyd0hrx
7n+ysJQaYdAqqO/vNOC0k8//nPsyuNI1Mml3e0KQ23P4OpvmPwc17sgufHd3YEh/
1xNDC3+IHi16dMgRo/1br7Y=
-----END PRIVATE KEY-----
EOF

oc create secret generic -n "${QUAYNAMESPACE}" --from-file config.yaml=./config.yaml --from-file default-cloudfront-signing-key.pem=./default-cloudfront-signing-key.pem config-bundle-secret

#Deploy Quay registry
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
