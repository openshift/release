#!/bin/bash

# GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
GIT_PR_NUMBER=1129


GITHUB_ORG_NAME="janus-idp"
GITHUB_REPOSITORY_NAME="backstage-showcase"
echo "whoami"
whoami

echo "Permission"
ls -ld $(pwd)

export HOME WORKSPACE CHROME_IMAGE CHROME_TAG
HOME=/tmp
WORKSPACE=$(pwd)

cd /tmp
echo "Permission"
ls -ld $(pwd)

# Clone and checkout the specific PR
# git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
git clone "https://github.com/subhashkhileri/backstage-showcase.git"
cd backstage-showcase
# git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
# git checkout PR"${GIT_PR_NUMBER}"

ls


GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
LONG_SHA=$(echo "${GIT_PR_RESPONSE}" | jq -r '.head.sha')
SHORT_SHA=$(git rev-parse --short "${LONG_SHA}")

echo "Tag name: pr-${GIT_PR_NUMBER}-${SHORT_SHA}"

TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
IMAGE_NAME="${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}:${TAG_NAME}"

# Get changeset from the main branch
PR_CHANGESET=$(git diff --name-only main)

echo "Changeset: ${PR_CHANGESET}"

# Define prefixes and directories to check
prefixes=("docs/" "showcase-docs/" ".changeset/")
DIRECTORIES_TO_CHECK=".ibm|e2e-tests"

# Function to check if tests should proceed based on changeset
checkProceedTest() {
    for file in $PR_CHANGESET; do
        for prefix in "${prefixes[@]}"; do
            if [[ "$file" == "$prefix"* ]]; then
                return 1 # Don't proceed if file matches prefix
            fi
        done
    done
    return 0 # Proceed if no file matches any prefix
}

# Function to check if changes are exclusively within specified directories
checkOnlyInDirs() {
    for change in $PR_CHANGESET; do
        if ! echo "$change" | grep -qE "^(${DIRECTORIES_TO_CHECK})/"; then
            return 1 # Not only in directories
        fi
    done
    return 0 # Only in specified directories
}


if checkProceedTest; then
    if checkOnlyInDirs; then
        echo "updated image tag : next"
        TAG_NAME="next"
    fi

    # Check if test runner script exists
    if [ -f ./.ibm/pipelines/openshift-tests.sh ]; then
        bash ./.ibm/pipelines/openshift-tests.sh
    else
        echo "Test runner script not found: ./.ibm/pipelines/openshift-tests.sh"
    fi
else
    echo "Skipping tests..."
    exit 0
fi

# Wait for Docker image
TIMEOUT=3000         # Maximum wait time of 50 mins (3000 seconds)
INTERVAL=60             # Check every 60 seconds

ELAPSED_TIME=0

while true; do
    response=$(curl -s "https://quay.io/api/v1/repository/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/tag/?specificTag=$TAG_NAME")
    tag_count=$(echo $response | jq '.tags | length')

    if [ "$tag_count" -gt "0" ]; then
        echo "Docker image $IMAGE_NAME is now available."
        exit 0
    fi

    sleep $INTERVAL
    ELAPSED_TIME=$(($ELAPSED_TIME + $INTERVAL))

    if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
        echo "Timed out waiting for Docker image $IMAGE_NAME."
        exit 1
    fi
done
