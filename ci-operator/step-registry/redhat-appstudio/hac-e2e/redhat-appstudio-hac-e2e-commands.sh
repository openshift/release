#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

# Install yq and go which is not present in used image (cypress/factory)

curl -Lso /tmp/bin/yq https://github.com/mikefarah/yq/releases/download/v4.25.2/yq_linux_amd64 && chmod +x /tmp/bin/yq
curl -Lso /tmp/go.tar.gz https://go.dev/dl/go1.20.3.linux-amd64.tar.gz && tar -C /tmp -xzf /tmp/go.tar.gz
PATH=$PATH:/tmp/go/bin

#  Setup env variables

export  OPENSHIFT_API OPENSHIFT_USERNAME OPENSHIFT_PASSWORD QONTRACT_BASE_URL \
     QONTRACT_PASSWORD QONTRACT_USERNAME HAC_SA_TOKEN CYPRESS_HAC_BASE_URL CYPRESS_GH_TOKEN CYPRESS_SSO_URL

QONTRACT_PASSWORD=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/qontract_password)
QONTRACT_USERNAME=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/qontract_username)
QONTRACT_BASE_URL="https://app-interface.devshift.net/graphql"
export CYPRESS_USERNAME=user1
export CYPRESS_PASSWORD=user1
export CYPRESS_PERIODIC_RUN=true
CYPRESS_GH_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github-token)
HAC_SA_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/c-rh-ceph_SA_bot)
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
OPENSHIFT_USERNAME="kubeadmin"

# Login to (hypershift) cluster

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' $KUBECONFIG
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    # Recommendation from hypershift qe team in slack channel..
    OPENSHIFT_PASSWORD="$(cat ${SHARED_DIR}/kubeadmin-password)"
else
    echo "Kubeadmin password file is empty... Aborting job"
    exit 1
fi

timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF
  if [ $? -ne 0 ]; then
	  echo "Timed out waiting for login"
	  exit 1
  fi

# Install HAC in ephemeral cluster
REF=main
if [ -n "$PULL_PULL_SHA" ] && [ "$REPO_NAME" = "infra-deployments" ]; then
  REF=$PULL_PULL_SHA
fi
echo $REF
curl https://raw.githubusercontent.com/redhat-appstudio/infra-deployments/$REF/hack/hac/installHac.sh -o installHac.sh

chmod +x installHac.sh
HAC_KUBECONFIG=/tmp/hac.kubeconfig
oc login --kubeconfig=$HAC_KUBECONFIG --token=$HAC_SA_TOKEN --server=https://api.c-rh-c-eph.8p0c.p1.openshiftapps.com:6443
echo "=== INSTALLING HAC ==="
HAC_NAMESPACE=$(./installHac.sh -ehk $HAC_KUBECONFIG -sk $KUBECONFIG |grep "Eph cluster namespace: " | sed "s/Eph cluster namespace: //g")
echo "=== HAC INSTALLED ==="
echo "HAC NAMESPACE: $HAC_NAMESPACE"
CYPRESS_HAC_BASE_URL="https://$(oc get feenv env-$HAC_NAMESPACE  --kubeconfig=$HAC_KUBECONFIG -o jsonpath="{.spec.hostname}")/preview/application-pipeline"
echo "Cypress Base url: $CYPRESS_HAC_BASE_URL"
CYPRESS_SSO_URL="$(oc get feenv env-$HAC_NAMESPACE --kubeconfig=$HAC_KUBECONFIG -o jsonpath="{.spec.sso}")"

echo "Deploying proxy plugin for tekton-results"
oc apply --kubeconfig=$KUBECONFIG -f - <<EOF
apiVersion: toolchain.dev.openshift.com/v1alpha1
kind: ProxyPlugin
metadata:
  name: tekton-results
  namespace: toolchain-host-operator
spec:
  openShiftRouteTargetEndpoint:
    name: tekton-results
    namespace: tekton-results
EOF

# Register user `user1`

cd /tmp/e2e
oc apply -f - <<EOF
apiVersion: toolchain.dev.openshift.com/v1alpha1
kind: UserSignup
metadata:
    name: user1
    namespace: toolchain-host-operator
    labels:
        toolchain.dev.openshift.com/email-hash: 826df0a2f0f2152550b0d9ee11099d85
    annotations:
        toolchain.dev.openshift.com/user-email: user1@user.us
spec:
    username: user1
    userid: user1
    approved: true
EOF
sleep 5
oc get UserSignup -n toolchain-host-operator

# Run tests

TEST_RUN=0
npm run cy:run -- --spec ./tests/basic-happy-path.spec.ts || TEST_RUN=1
cp -a /tmp/e2e/cypress/* ${ARTIFACT_DIR}

## Release bonfire namespace
BONFIRE_NAMESPACE=$(oc get --kubeconfig=$HAC_KUBECONFIG NamespaceReservations -o jsonpath="{.items[?(@.status.namespace==\"$HAC_NAMESPACE\")].metadata.name}")
oc patch --kubeconfig=$HAC_KUBECONFIG NamespaceReservations/"$BONFIRE_NAMESPACE" --type=merge --patch-file=/dev/stdin <<-EOF
{
    "spec": {
        "duration": "0s"
    }
}
EOF
exit $TEST_RUN
