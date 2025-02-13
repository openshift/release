#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Get the credentials and Email of new Quay User
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

#Deploy ODF Operator to OCP namespace 'openshift-storage'
OO_INSTALL_NAMESPACE=openshift-storage
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
ODF_OPERATOR_CHANNEL="$ODF_OPERATOR_CHANNEL"
ODF_SUBSCRIPTION_NAME="$ODF_SUBSCRIPTION_NAME"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)
if [[ -n "$OPERATORGROUP" ]]; then
  echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
  OG_OPERATION=apply
  OG_NAMESTANZA="name: $OPERATORGROUP"
else
  echo "OperatorGroup does not exist: creating it"
  OG_OPERATION=create
  OG_NAMESTANZA="generateName: oo-"
fi

OPERATORGROUP=$(
  oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: $OO_INSTALL_NAMESPACE
spec:
  targetNamespaces: [$OO_INSTALL_NAMESPACE]
EOF
)

SUB=$(
  cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $ODF_SUBSCRIPTION_NAME
  namespace: $OO_INSTALL_NAMESPACE
spec:
  channel: $ODF_OPERATOR_CHANNEL
  installPlanApproval: Automatic
  name: $ODF_SUBSCRIPTION_NAME
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)

for _ in {1..60}; do
  CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ClusterServiceVersion \"$CSV\" ready"
      break
    fi
  fi
  sleep 10
done
echo "ODF/OCS Operator is deployed successfully"

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
#https://access.redhat.com/documentation/en-us/red_hat_quay/3.8/html-single/deploying_the_red_hat_quay_operator_on_openshift_container_platform/index#creating-standalone-object-gateway
cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: noobaa
  namespace: openshift-storage
spec:
  dbResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  coreResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  dbType: postgres
EOF

echo "Waiting for NooBaa Storage to be ready..." >&2
oc -n openshift-storage wait noobaa.noobaa.io/noobaa --for=condition=Available --timeout=180s

#Create Quay Config Bundle Secret
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
IGNORE_UNKNOWN_MEDIATYPES: true
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
EOF

echo "Creating Quay Config Bundle Secret..." >&2
chmod 777 config.yaml && oc create secret generic --from-file config.yaml=./config.yaml config-bundle-secret -n quay-enterprise

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
  if [[ "$(oc -n quay-enterprise get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" == "True" ]]; then
    echo "Quay is in ready status" >&2
    oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}' > "$SHARED_DIR"/quayroute || true
    quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}') || true
    echo "Quay Route is $quay_route" || true
    curl -k -X POST $quay_route/api/v1/user/initialize --header 'Content-Type: application/json' \
         --data '{ "username": "'$QUAY_USERNAME'", "password": "'$QUAY_PASSWORD'", "email": "'$QUAY_EMAIL'", "access_token": true }' | jq '.access_token' | tr -d '"' | tr -d '\n' > "$SHARED_DIR"/quay_oauth2_token || true
    curl -k $quay_route/api/v1/discovery | jq > "$SHARED_DIR"/quay_api_discovery
    cp "$SHARED_DIR"/quay_api_discovery "$ARTIFACT_DIR"/quay_api_discovery || true
    exit 0
  fi
  sleep 15
done
echo "Timed out waiting for Quay to become ready afer 15 mins" >&2
oc -n quay-enterprise get quayregistries -o yaml >"$ARTIFACT_DIR"/quayregistries.yaml || true
exit 2
