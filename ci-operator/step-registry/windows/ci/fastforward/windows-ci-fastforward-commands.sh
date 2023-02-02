#!/bin/bash
set -eo pipefail

wmco_dir=$(mktemp -d -t wmco-XXXXX)
cd "$wmco_dir" || exit 1

echo "INFO Checking settings"
echo "    REPO_OWNER         = $REPO_OWNER"
echo "    REPO_NAME          = $REPO_NAME"
echo "    JOB_TYPE           = $JOB_TYPE"
echo "    GITHUB_USER        = $GITHUB_USER"
echo "    GITHUB_TOKEN_FILE  = $GITHUB_TOKEN_FILE"
echo "    SOURCE_BRANCH      = $SOURCE_BRANCH"
echo "    DESTINATION_BRANCH = $DESTINATION_BRANCH"

if [[ "$JOB_TYPE" != "postsubmit" ]]; then
    echo "ERROR This workflow may only be run as a postsubmit job"
    exit 1
fi

if [[ -z "$GITHUB_USER" ]]; then
    echo "ERROR GITHUB_USER may not be empty"
    exit 1
fi

if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    echo "ERROR GITHUB_TOKEN_FILE missing or not readable"
    exit 1
fi

if [[ -z "$SOURCE_BRANCH" ]]; then
    echo "ERROR SOURCE_BRANCH may not be empty"
    exit 1
fi

if [[ -z "$DESTINATION_BRANCH" ]]; then
    echo "ERROR DESTINATION_BRANCH may not be empty"
    exit 1
fi

echo "INFO Cloning $DESTINATION_BRANCH"
token=$(cat "$GITHUB_TOKEN_FILE")
repo="github.com/$REPO_OWNER/$REPO_NAME"
repo_url="https://${GITHUB_USER}:${token}@${repo}.git"

if ! git clone -b "$DESTINATION_BRANCH" "$repo_url" ; then
    echo "INFO $DESTINATION_BRANCH does not exist. Will create it"
    echo "INFO Cloning $SOURCE_BRANCH"
    if ! git clone -b "$SOURCE_BRANCH" "$repo_url" ; then
        echo "ERROR Could not clone $SOURCE_BRANCH"
        echo "      repo_url = $repo_url"
        exit 1
    fi

    echo "INFO Changing into repo directory"
    cd "$REPO_NAME" || exit 1

    echo "INFO Checking out new $DESTINATION_BRANCH"
    if ! git checkout -b "$DESTINATION_BRANCH" ; then
        echo "ERROR Could not checkout $DESTINATION_BRANCH"
        exit 1
    fi

    echo "INFO Pushing the following commits to $DESTINATION_BRANCH to origin"
    git --no-pager log --pretty=oneline origin/"$DESTINATION_BRANCH"..HEAD
    if ! git push origin $DESTINATION_BRANCH; then
        echo "ERROR Could not push to origin DESTINATION_BRANCH"
        exit 1
    fi

    echo "INFO Fast forward complete"
    exit 0
fi

echo "INFO Changing into repo directory"
cd "$REPO_NAME" || exit 1

echo "INFO Pulling from SOURCE_BRANCH into $DESTINATION_BRANCH"
if ! git pull --ff-only origin "$SOURCE_BRANCH" ; then
    echo "ERROR Could not pull from $SOURCE_BRANCH"
    exit 1
fi

echo "INFO Pushing the following commits to origin/$DESTINATION_BRANCH"
git --no-pager log --pretty=oneline origin/"$DESTINATION_BRANCH"..HEAD
if ! git push origin $DESTINATION_BRANCH; then
    echo "ERROR Could not push to DESTINATION_BRANCH"
   exit 1
fi

echo "INFO Fast forward complete"

