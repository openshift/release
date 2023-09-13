#!/bin/bash

# There are alot of OSCI env variables to configure this is a way to configure 
# without mapping all of them directly in the step registry.
if [[ -n "${OSCI_ENV_CONFIG:-}" ]]; then
    readarray -t config <<< "${OSCI_ENV_CONFIG}"
    for var in "${config[@]}"; do
        if [[ -n "${var}" ]]; then
            echo "export ${var}" >> "${SHARED_DIR}/osci-env-config"
        fi
    done

    # We create this file above - Ignore SC1091
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/osci-env-config"
fi

# Set defaults for OCM pipeline and repo if not set.
export OSCI_PIPELINE_SITE=${OSCI_PIPELINE_SITE:-github.com}
export OSCI_PIPELINE_ORG=${OSCI_PIPELINE_ORG:-stolostron}
export OSCI_PIPELINE_REPO=${OSCI_PIPELINE_REPO:-pipeline}
export OSCI_IMAGE_REMOTE_REPO=${OSCI_IMAGE_REMOTE_REPO:-quay.io/stolostron}
export OSCI_IMAGE_REMOTE_REPO_SRC=${OSCI_IMAGE_REMOTE_REPO_SRC:-registry.ci.openshift.org/stolostron}

# This is to satisfy shellcheck SC2153
export RELEASE_REPO=${RELEASE_REPO}

export HOME=/tmp/home
mkdir -p "$HOME/.docker"
cd "$HOME" || exit 1

# Note: REPO_NAME and REPO_OWNER are not available in periodic type jobs. Prow docs link below.
# https://github.com/kubernetes/test-infra/blob/master/prow/jobs.md#job-environment-variables
# We wouldn't have the infromation needed to do the business echoic in a periodic run.
if [[ "$JOB_TYPE" == "periodic" ]]; then
    echo "ERROR Cannot update the manifest from a $JOB_TYPE job"
    exit 1
fi

# Check to see if running in openshift/release -> set DRY_RUN to true
if [[ "$REPO_OWNER" == "openshift" && "$REPO_NAME" == "release" ]]; then
    echo "INFO Running in openshift/release, setting DRY_RUN to true"
    DRY_RUN="true"
fi

# Setup GitHub credentials for release repo
GITHUB_TOKEN_FILE="$SECRETS_PATH/$GITHUB_SECRET/$GITHUB_SECRET_FILE"
echo "INFO Setting up git credentials."
if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    echo "ERROR GitHub token file missing or not readable: $GITHUB_TOKEN_FILE"
    exit 1
fi
GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
{
    echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@${RELEASE_REPO}.git"
} >> ghcreds
git config --global credential.helper 'store --file=ghcreds'

# Set up repo URLs
release_url="https://${RELEASE_REPO}.git"

# Clone repos
release_dir="$HOME/release"

echo "INFO Cloning the RELEASE_REPO: ${RELEASE_REPO} into ${release_dir}"
git clone "$release_url" "$release_dir" || {
    echo "ERROR Could not clone release repo $release_url"
    exit 1
}

# Determine current release branch
branch="${PULL_BASE_REF}"
echo "INFO The base branch is $branch"

if [[ -n "$RELEASE_REF" ]]; then
    if [ -z "$OSCI_RELEASE_BRANCH" ]; then
        echo "INFO OSCI_RELEASE_BRANCH variable is not set. Using $RELEASE_REF for OSCI_COMPONENT_BRANCH."
        export OSCI_COMPONENT_BRANCH=${RELEASE_REF}
    fi
    echo "INFO RELEASE_REF variable is set. Using $RELEASE_REF as branch."
    branch="${RELEASE_REF}"
fi

if [[ -z "$OSCI_COMPONENT_VERSION" ]]; then
    # Get current Z-stream version and set to OSCI_COMPONENT_VERSION if this is not set
    cd "$release_dir" || exit 1
    git checkout "$branch" || {
        echo "ERROR Could not checkout branch $branch in OCM release repo"
        exit 1
    }
    release=$(cat "$release_dir/Z_RELEASE_VERSION")
    echo "INFO Z-stream version is $release"
    export OSCI_COMPONENT_VERSION=$release
fi

echo "INFO OSCI_COMPONENT_VERSION is ${OSCI_COMPONENT_VERSION}"

# Set OSCI_COMPONENT_NAME to REPO_NAME if it is not provided
export OSCI_COMPONENT_NAME=${OSCI_COMPONENT_NAME:-$REPO_NAME}
echo "INFO OSCI_COMPONENT_NAME is ${OSCI_COMPONENT_NAME}."

# Debug information - Only match environment variables starting with OSCI_
echo "INFO OSCI Environment variables are set to: "
env | grep -e "^OSCI_.*$"

if [[ "$DRY_RUN" == "false" ]]; then
    # We check for postsubmit specifically because we need a new image published 
    # before running this step. Putting this check down here means that this step
    # is rehearsable in openshift/release.
    if [[ ! ("$JOB_TYPE" = "postsubmit" ) ]]; then
        echo "ERROR Cannot update the manifest from a $JOB_TYPE job"
        exit 1
    fi

    # Run manifest update
    cd /opt/build-harness/build-harness-extensions/modules/osci/ || exit 1
    # TODO: Look into if there is a better way to use this shell script and Makefile.
    # Location of script and Makefile: https://github.com/stolostron/build-harness-extensions/tree/main/modules/osci
    # Some these are set in the Makefile template as well. Lots of includes so it is hard to follow.
    # Location of Makefile template: https://github.com/stolostron/build-harness-extensions/blob/main/templates/Makefile.build-harness-openshift-ci
    make osci/publish BUILD_HARNESS_EXTENSIONS_PATH=/opt/build-harness/build-harness-extensions GITHUB_USER=acm-cicd%40redhat.com "GITHUB_TOKEN=$GITHUB_TOKEN"
else
    echo "INFO DRY_RUN is set to $DRY_RUN. Exiting without publishing changes to OCM manifest."
fi
