#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Create AWS S3 Storage Bucket
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"

QUAY_IBMCOS_ACCESS_KEY=$(cat /var/run/quay-qe-ibmcos-secret/access_key)
QUAY_IBMCOS_SECRET_KEY=$(cat /var/run/quay-qe-ibmcos-secret/secret_key)
QUAY_IBMCOS_HOST_NAME=$(cat /var/run/quay-qe-ibmcos-secret/hostname)
QUAY_IBMCOS_BUCKET_NAME=$(cat /var/run/quay-qe-ibmcos-secret/bucket_name)

#Deploy Quay Operator to OCP namespace 'quay-enterprise'
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: quay-enterprise
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  targetNamespaces:
  - quay-enterprise
EOF

SUB=$(
  cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: quay-enterprise
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: $QUAY_OPERATOR_CHANNEL
  source: $QUAY_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

echo "The Quay Operator subscription is $SUB"

for _ in {1..60}; do
  CSV=$(oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n quay-enterprise get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ClusterServiceVersion \"$CSV\" ready"
      break
    fi
  fi
  sleep 10
done
echo "Quay Operator is deployed successfully"

#Deploy Quay, here disable monitoring component
cat >>config.yaml <<EOF
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_PROXY_CACHE: true
FEATURE_USER_INITIALIZE: true
SUPER_USERS:
  - quay
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - IBMCloudStorage
    - bucket_name: $QUAY_IBMCOS_BUCKET_NAME
      storage_path: /quay310
      is_secure: true
      access_key: $QUAY_IBMCOS_ACCESS_KEY
      secret_key: $QUAY_IBMCOS_SECRET_KEY
      hostname: $QUAY_IBMCOS_HOST_NAME
EOF

oc create secret generic -n quay-enterprise --from-file config.yaml=./config.yaml config-bundle-secret

echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay-enterprise
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

for _ in {1..60}; do
  if [[ "$(oc -n quay-enterprise get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    echo "Quay is in ready status" >&2
    exit 0
  fi
  sleep 15
done
echo "Timed out waiting for Quay to become ready afer 15 mins" >&2
oc -n quay-enterprise get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
