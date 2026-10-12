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

QUAY_REPO="rhdh-community/rhdh-plugin-certification"
export QUAY_REPO

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
oc create serviceaccount tester-sa-2 -n default
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2
K8S_CLUSTER_TOKEN=$(oc create token tester-sa-2 -n default)
oc logout

export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh-plugin-certification"

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd rhdh-plugin-certification || exit

git config --global user.name "rhdh-cert"
git config --global user.email "rhdh-cert@redhat.com"

if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    git merge origin/main --no-edit
    GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
    LONG_SHA=$(echo "$GIT_PR_RESPONSE" | jq -r '.head.sha')
    SHORT_SHA=$(git rev-parse --short=8 ${LONG_SHA})
    TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "Tag name: $TAG_NAME"
    # IMAGE_NAME="${QUAY_REPO}:${TAG_NAME}"
fi

PR_CHANGESET=$(git diff --name-only main)
echo "Changeset: $PR_CHANGESET"

echo "Starting Certification Tests"
bash ./.automation/pipelines/rhdh_certify.sh

