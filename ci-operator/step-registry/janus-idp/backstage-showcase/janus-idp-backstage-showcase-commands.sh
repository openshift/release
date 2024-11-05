#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
GITHUB_ORG_NAME="janus-idp"
GITHUB_REPOSITORY_NAME="backstage-showcase"

# Define branch and PR conditions
TARGET_BRANCH="main"
ALLOWED_PR_ON_MAIN="1869"
RELEASE_BRANCH="release-1.3"

# Extract the base branch name
BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.refs.base_ref')

# Check conditions for running e2e tests
if [ "$BRANCH_NAME" == "$TARGET_BRANCH" ] && [ "$GIT_PR_NUMBER" != "$ALLOWED_PR_ON_MAIN" ]; then
    echo "Only PR $ALLOWED_PR_ON_MAIN is allowed to run e2e tests on main branch. Exiting script."
    exit 0
elif [ "$BRANCH_NAME" != "$RELEASE_BRANCH" ] && [ "$BRANCH_NAME" != "$TARGET_BRANCH" ]; then
    echo "e2e tests are only allowed on main and release-1.3 branches. Exiting script."
    exit 0
fi

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd backstage-showcase || exit

git config --global user.name "rhdh-qe"
git config --global user.email "rhdh-qe@redhat.com"

if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    git merge origin/main --no-edit
    GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
    LONG_SHA=$(echo "$GIT_PR_RESPONSE" | jq -r '.head.sha')
    SHORT_SHA=$(git rev-parse --short ${LONG_SHA})
    TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "Tag name: $TAG_NAME"
    IMAGE_NAME="${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}:${TAG_NAME}"
fi

PR_CHANGESET=$(git diff --name-only main)
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

if $ONLY_IN_DIRS || [[ "$JOB_NAME" == rehearse-* ]]; then
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

bash ./.ibm/pipelines/openshift-ci-tests.sh
