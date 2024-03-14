#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

export OPENSHIFT_PASSWORD OPENSHIFT_API RED_HAT_DEVELOPER_HUB_URL GITHUB_TOKEN \
    GITHUB_ORGANIZATION QUAY_IMAGE_ORG APPLICATION_ROOT_NAMESPACE NODE_TLS_REJECT_UNAUTHORIZED

echo "start rhtap-installer e2e test"

OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u kubeadmin -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
        sleep 20
    done
EOF

APPLICATION_ROOT_NAMESPACE="rhtap-e2e-ci"
QUAY_IMAGE_ORG="rhtap_qe"
GITHUB_ORGANIZATION="rhtap-rhdh-qe"
GITHUB_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gihtub_token)
RED_HAT_DEVELOPER_HUB_URL=https://"$(oc get route developer-hub -n rhtap -o jsonpath='{.spec.host}')"

cd "$(mktemp -d)"

git clone https://github.com/redhat-appstudio/rhtap-e2e.git .

/bin/bash ./scripts/create-creds.sh "${APPLICATION_ROOT_NAMESPACE}"

NODE_TLS_REJECT_UNAUTHORIZED=0
yarn && yarn test
