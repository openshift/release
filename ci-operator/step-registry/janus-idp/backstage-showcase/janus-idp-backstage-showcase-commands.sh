#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE TAG_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
GITHUB_ORG_NAME="janus-idp"
GITHUB_REPOSITORY_NAME="backstage-showcase"
NAME_SPACE=showcase-ci

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd backstage-showcase || exit

if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # if this is executed as PR check of https://github.com/janus-idp/backstage-showcase.git repo, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
    LONG_SHA=$(echo "$GIT_PR_RESPONSE" | jq -r '.head.sha')
    SHORT_SHA=$(git rev-parse --short ${LONG_SHA})
    TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "Tag name: $TAG_NAME"
    IMAGE_NAME="${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}:${TAG_NAME}"
fi

PR_CHANGESET=$(git diff --name-only main)
echo "Changeset: $PR_CHANGESET"

# Directories to check if changes are exclusively within the specified directories
DIRECTORIES_TO_CHECK=".ibm|e2e-tests"
ONLY_IN_DIRS=true

for change in $PR_CHANGESET; do
    # Check if the change is not within the specified directories
    if ! echo "$change" | grep -qE "^($DIRECTORIES_TO_CHECK)/"; then
        ONLY_IN_DIRS=false
        break
    fi
done

if [ $ONLY_IN_DIRS ] || [[ "$JOB_NAME" == rehearse-* ]]; then
    echo "Skipping wait for new PR image and proceeding with image tag : next"
    echo "updated image tag : next"
    TAG_NAME="next"
else
    TIMEOUT=3000         # Maximum wait time of 50 mins (3000 seconds)
    INTERVAL=60             # Check every 60 seconds

    ELAPSED_TIME=0

    while true; do
        # Check image availability
        response=$(curl -s "https://quay.io/api/v1/repository/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/tag/?specificTag=$TAG_NAME")

        # Use jq to parse the JSON and see if the tag exists
        tag_count=$(echo $response | jq '.tags | length')

        if [ "$tag_count" -gt "0" ]; then
            echo "Docker image $IMAGE_NAME is now available."
            break
        fi

        # Wait for the interval duration
        sleep $INTERVAL

        # Increment the elapsed time
        ELAPSED_TIME=$(($ELAPSED_TIME + $INTERVAL))

        # If the elapsed time exceeds the timeout, exit with an error
        if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
            echo "Timed out waiting for Docker image $IMAGE_NAME."
            exit 1
        fi
    done

fi

bash ./.ibm/pipelines/openshift-ci-tests.sh
