#!/bin/sh

# Run the command for upgrade testing
if [[ ! "${TEST_SUITE}" =~ "Upgrade" ]]; then
  echo "Prepare Catalog Source for Upgrade testing."
else
  exit 0
fi

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export KUBECONFIG=$SHARED_DIR/kubeconfig

# login to set up catalog source
OCP_CRED_USR="kubeadmin"
export OCP_CRED_USR
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
export OCP_CRED_PSW
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

QUAY_INFO="/tmp/secrets/ci"

# create quay pull secret
secrets=$(mktemp -d)
oc extract secret/pull-secret -n openshift-config --to="${secrets}"
if ! grep 'quay.io/rhoai' < "${secrets}"/.dockerconfigjson
then
  jq '.auths["quay.io/rhoai"] = {"auth": "'$(cat ${QUAY_INFO}/quay_token)'"}' "${secrets}"/.dockerconfigjson > "${secrets}"/.dockerconfigjson_update
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${secrets}"/.dockerconfigjson_update
fi

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: pull-secret
  namespace: openshift-marketplace
---
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: quay-registry
spec:
  repositoryDigestMirrors:
    - source: registry.redhat.io/rhoai
      mirrors:
        - quay.io/rhoai
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: rhoai-catalog-dev
  namespace: openshift-marketplace
spec:
  displayName: OpenShift AI Pre-Release
  publisher: RHOAI Development Catalog
  image: quay.io/rhoai/rhoai-fbc-fragment:rhoai-2.17
  sourceType: grpc
  secrets:
     - pull-secret
EOF

sleep 300

echo "Checking custom catalog..."
oc get catalogsource -n openshift-marketplace

