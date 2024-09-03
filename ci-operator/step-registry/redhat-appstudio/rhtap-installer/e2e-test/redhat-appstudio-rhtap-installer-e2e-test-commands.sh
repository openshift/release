#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

export OPENSHIFT_PASSWORD OPENSHIFT_API RED_HAT_DEVELOPER_HUB_URL GITHUB_TOKEN \
    GITHUB_ORGANIZATION QUAY_IMAGE_ORG APPLICATION_ROOT_NAMESPACE NODE_TLS_REJECT_UNAUTHORIZED GITLAB_TOKEN \
    GITLAB_ORGANIZATION

echo "start rhtap-installer e2e test"

OPENSHIFT_PASSWORD="$(cat "$KUBEADMIN_PASSWORD_FILE")"
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' "$KUBECONFIG")"
GITLAB_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gitlab_token)
GITLAB_ORGANIZATION="rhtap-qe"
#GITLAB_WEBHOOK_SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-webhook-secret)

timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u kubeadmin -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
        sleep 20
    done
EOF

APPLICATION_ROOT_NAMESPACE="rhtap-app"
QUAY_IMAGE_ORG="rhtap_qe"
GITHUB_ORGANIZATION="rhtap-rhdh-qe"
GITHUB_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gihtub_token)
RED_HAT_DEVELOPER_HUB_URL=https://"$(oc get route backstage-developer-hub -n rhtap -o jsonpath='{.spec.host}')"

cd "$(mktemp -d)"

git clone https://github.com/redhat-appstudio/rhtap-e2e.git .

NODE_TLS_REJECT_UNAUTHORIZED=0
yarn && yarn test
