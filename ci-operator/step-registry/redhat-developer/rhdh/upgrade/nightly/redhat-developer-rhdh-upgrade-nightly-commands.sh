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

export NAME_SPACE="showcase-upgrade-nightly"

# Prepare to git checkout
export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"

export QUAY_REPO RELEASE_BRANCH_NAME
QUAY_REPO="rhdh-community/rhdh"
# Get the base branch name based on job.
RELEASE_BRANCH_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo ${JOB_SPEC} | jq -r '.refs.base_ref')

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}" || exit
git checkout "$RELEASE_BRANCH_NAME" || exit

git config --global user.name "rhdh-qe"
git config --global user.email "rhdh-qe@redhat.com"

if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    git merge origin/$RELEASE_BRANCH_NAME --no-edit
    GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
    LONG_SHA=$(echo "$GIT_PR_RESPONSE" | jq -r '.head.sha')
    SHORT_SHA=$(git rev-parse --short=8 ${LONG_SHA})
    TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "Tag name: $TAG_NAME"
    IMAGE_NAME="${QUAY_REPO}:${TAG_NAME}"
fi

PR_CHANGESET=$(git diff --name-only $RELEASE_BRANCH_NAME)
echo "Changeset: $PR_CHANGESET"

# Check if changes are exclusively within the specified directories
DIRECTORIES_TO_CHECK=".ibm|e2e-tests"
ONLY_IN_DIRS=true

for change in $PR_CHANGESET; do
    # Check if the change is not within the specified directories
    if ! echo "$change" | grep -qE "^($DIRECTORIES_TO_CHECK)/"; then
        ONLY_IN_DIRS=false
        break
    fi
done

if [[ "$JOB_NAME" == rehearse-* || "$JOB_TYPE" == "periodic" ]]; then
    QUAY_REPO="rhdh/rhdh-hub-rhel9"
    if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
        # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
        TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
    else
        TAG_NAME="next"
    fi
elif [[ "$ONLY_IN_DIRS" == "true" && "$JOB_TYPE" == "presubmit" ]];then
    if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
        QUAY_REPO="rhdh/rhdh-hub-rhel9"
        # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
        TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
    else
        QUAY_REPO="rhdh-community/rhdh"
        TAG_NAME="next"
    fi
    echo "INFO: Bypassing PR image build wait, using tag: ${TAG_NAME}"
    echo "INFO: Container image will be tagged as: ${QUAY_REPO}:${TAG_NAME}"
else
    TIMEOUT=3000         # Maximum wait time of 50 mins (3000 seconds)
    INTERVAL=60             # Check every 60 seconds

    ELAPSED_TIME=0

    while true; do
        # Check image availability
        response=$(curl -s "https://quay.io/api/v1/repository/${QUAY_REPO}/tag/?specificTag=$TAG_NAME")

        # Use jq to parse the JSON and see if the tag exists
        tag_count=$(echo $response | jq '.tags | length')

        if [ "$tag_count" -gt "0" ]; then
            echo "Docker image $IMAGE_NAME is now available. Time elapsed: $(($ELAPSED_TIME / 60)) minute(s)."
            break
        fi

        # Wait for the interval duration
        sleep $INTERVAL

        # Increment the elapsed time
        ELAPSED_TIME=$(($ELAPSED_TIME + $INTERVAL))

        # If the elapsed time exceeds the timeout, exit with an error
        if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
            echo "Timed out waiting for Docker image $IMAGE_NAME. Time elapsed: $(($ELAPSED_TIME / 60)) minute(s)."
            exit 1
        fi
    done
fi

echo "############## Current branch ##############"
echo "Current branch: $(git branch --show-current)"
echo "Using Image: ${QUAY_REPO}:${TAG_NAME}"


bash ./.ibm/pipelines/openshift-ci-tests.sh
