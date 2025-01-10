#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

export OPENSHIFT_PASSWORD
export OPENSHIFT_API
export OPENSHIFT_USERNAME

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' "$KUBECONFIG")"
OPENSHIFT_USERNAME="kubeadmin"

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' "$KUBECONFIG"
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat "$KUBEADMIN_PASSWORD_FILE")"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    # Recommendation from hypershift qe team in slack channel..
    OPENSHIFT_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
else
    echo "Kubeadmin password file is empty... Aborting job"
    exit 1
fi

timeout --foreground 5m bash <<-"EOF"
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF
if [ $? -ne 0 ]; then
    echo "Timed out waiting for login"
    exit 1
fi

export K8S_CLUSTER_URL K8S_CLUSTER_TOKEN
K8S_CLUSTER_URL=$(oc whoami --show-server)
echo "K8S_CLUSTER_URL: $K8S_CLUSTER_URL"

echo "Note: This cluster will be automatically deleted 4 hours after being claimed."
echo "To debug issues or log in to the cluster manually, use the script: .ibm/pipelines/ocp-cluster-claim-login.sh"

oc create serviceaccount tester-sa-2 -n default
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2
K8S_CLUSTER_TOKEN=$(oc create token tester-sa-2 -n default)
oc logout

echo "OC_CLIENT_VERSION: $OC_CLIENT_VERSION"

mkdir -p /tmp/openshift-client
# Download and Extract the oc binary
wget -O /tmp/openshift-client/openshift-client-linux-$OC_CLIENT_VERSION.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OC_CLIENT_VERSION/openshift-client-linux.tar.gz
tar -C /tmp/openshift-client -xvf /tmp/openshift-client/openshift-client-linux-$OC_CLIENT_VERSION.tar.gz
export PATH=/tmp/openshift-client:$PATH
oc version

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE NAME_SPACE_RBAC TAG_NAME

GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"
NAME_SPACE="showcase-operator-nightly"
NAME_SPACE_RBAC="showcase-op-rbac-nightly"
TAG_NAME="next"

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd rhdh || exit

bash ./.ibm/pipelines/openshift-ci-tests.sh
