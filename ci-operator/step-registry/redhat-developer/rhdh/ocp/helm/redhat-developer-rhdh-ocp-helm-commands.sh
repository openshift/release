#!/bin/bash

echo "========== Repository, Branch, and PR Variables =========="
GITHUB_ORG_NAME="redhat-developer"
echo "GITHUB_ORG_NAME: $GITHUB_ORG_NAME"
GITHUB_REPOSITORY_NAME="rhdh"
echo "GITHUB_REPOSITORY_NAME: $GITHUB_REPOSITORY_NAME"
RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')
echo "RELEASE_BRANCH_NAME: $RELEASE_BRANCH_NAME"
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER: $GIT_PR_NUMBER"
TAG_NAME=""
export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME RELEASE_BRANCH_NAME GIT_PR_NUMBER TAG_NAME

echo "========== Check for [skip-e2e] commit comments in the PR title =========="
# Check for [skip-e2e] commit comments in the PR title
if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    PR_TITLE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}" | jq -r '.title')
    # only skip e2e tests for a [skip-e2e] PR that has been auto-approved by github-actions[bot]
    if [[ "$PR_TITLE" == *"[skip-e2e]"* ]]; then
        echo "PR_TITLE: $PR_TITLE"
        APPROVALS=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}/reviews") # json array of approvals
        # iterate through the approvals and check if the approval is from the .user.login = "github-actions[bot]" and if the .state = "APPROVED" 
        approval_count=$(echo "$APPROVALS" | jq 'length')
        for ((i=0; i<approval_count; i++)); do
            user_login=$(echo "$APPROVALS" | jq -r ".[$i].user.login")
            state=$(echo "$APPROVALS" | jq -r ".[$i].state")
            if [[ "$user_login" == "github-actions[bot]" ]] && [[ "$state" == "APPROVED" ]]; then
                echo "Auto-approved by github-actions[bot], so no need to run tests; skip all test execution with exit code 0"
                exit 0
            fi
        done
    fi
fi

echo "========== Workdir Setup =========="
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "========== Cluster Authentication =========="
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

echo "========== Cluster Service Account and Token Management =========="
export K8S_CLUSTER_URL K8S_CLUSTER_TOKEN
K8S_CLUSTER_URL=$(oc whoami --show-server)
echo "K8S_CLUSTER_URL: $K8S_CLUSTER_URL"

echo "Note: This cluster will be automatically deleted 4 hours after being claimed."
echo "To debug issues or log in to the cluster manually, use the script: .ibm/pipelines/ocp-cluster-claim-login.sh"

oc create serviceaccount tester-sa-2 -n default
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2
K8S_CLUSTER_TOKEN=$(oc create token tester-sa-2 -n default --duration=4h)

echo "========== Platform Environment Variables =========="
echo "Setting platform environment variables:"
export IS_OPENSHIFT="true"
echo "IS_OPENSHIFT=${IS_OPENSHIFT}"
export CONTAINER_PLATFORM="ocp"
echo "CONTAINER_PLATFORM=${CONTAINER_PLATFORM}"
echo "Getting container platform version"
CONTAINER_PLATFORM_VERSION=$(oc version --output json 2> /dev/null | jq -r '.openshiftVersion' | cut -d'.' -f1,2 || echo "unknown")
export CONTAINER_PLATFORM_VERSION
echo "CONTAINER_PLATFORM_VERSION=${CONTAINER_PLATFORM_VERSION}"

echo "========== Cluster kubeadmin logout =========="
oc logout

echo "========== Git Repository Setup & Checkout =========="
QUAY_REPO="rhdh-community/rhdh"
export QUAY_REPO

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}" || exit
git checkout "$RELEASE_BRANCH_NAME" || exit

git config --global user.name "rhdh-qe"
git config --global user.email "rhdh-qe@redhat.com"

echo "========== PR Branch Handling =========="
if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    git merge origin/$RELEASE_BRANCH_NAME --no-edit
    GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
    LONG_SHA=$(echo "$GIT_PR_RESPONSE" | jq -r '.head.sha')
    SHORT_SHA=$(git rev-parse --short=8 ${LONG_SHA})
    TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "TAG_NAME: $TAG_NAME"
    IMAGE_NAME="${QUAY_REPO}:${TAG_NAME}"
    echo "IMAGE_NAME: $IMAGE_NAME"
fi

echo "========== Changeset Analysis =========="
PR_CHANGESET=$(git diff --name-only $RELEASE_BRANCH_NAME)
echo "Changeset: $PR_CHANGESET"

# Check if changes are exclusively within the specified directories
DIRECTORIES_TO_CHECK=".ibm|e2e-tests|docs|.claude|.cursor|.rulesync|.vscode"
ONLY_IN_DIRS=true

for change in $PR_CHANGESET; do
    # Check if the change is not within the specified directories
    if ! echo "$change" | grep -qE "^($DIRECTORIES_TO_CHECK)/"; then
        ONLY_IN_DIRS=false
        break
    fi
done

echo "ONLY_IN_DIRS: $ONLY_IN_DIRS"

echo "========== Image Tag Resolution =========="
if [[ "$JOB_NAME" == rehearse-* || "$JOB_TYPE" == "periodic" ]]; then
    QUAY_REPO="rhdh/rhdh-hub-rhel9"
    if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
        # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
        TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
    else
        TAG_NAME="next"
    fi
    echo "TAG_NAME: $TAG_NAME"
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
    echo "Waiting for Docker image availability..."
    # Timeout configuration for waiting for Docker image availability
    MAX_WAIT_TIME_SECONDS=$((80*60))    # Maximum wait time: 1 hour 20 minutes
    POLL_INTERVAL_SECONDS=60      # Check every 60 seconds

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
        sleep $POLL_INTERVAL_SECONDS

        # Increment the elapsed time
        ELAPSED_TIME=$(($ELAPSED_TIME + $POLL_INTERVAL_SECONDS))

        # If the elapsed time exceeds the timeout, exit with an error
        if [ $ELAPSED_TIME -ge $MAX_WAIT_TIME_SECONDS ]; then
            echo "Timed out waiting for Docker image $IMAGE_NAME. Time elapsed: $(($ELAPSED_TIME / 60)) minute(s)."
            exit 1
        fi
    done
fi

echo "========== Current branch =========="
echo "Current branch: $(git branch --show-current)"
echo "Using Image: ${QUAY_REPO}:${TAG_NAME}"

echo "========== Test Execution =========="
echo "Executing openshift-ci-tests.sh"
bash ./.ibm/pipelines/openshift-ci-tests.sh
