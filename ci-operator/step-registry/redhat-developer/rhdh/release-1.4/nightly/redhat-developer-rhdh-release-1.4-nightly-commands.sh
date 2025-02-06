#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "OC_CLIENT_VERSION: $OC_CLIENT_VERSION"

mkdir -p /tmp/openshift-client
# Download and Extract the oc binary
wget -O /tmp/openshift-client/openshift-client-linux-$OC_CLIENT_VERSION.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OC_CLIENT_VERSION/openshift-client-linux.tar.gz
tar -C /tmp/openshift-client -xvf /tmp/openshift-client/openshift-client-linux-$OC_CLIENT_VERSION.tar.gz
export PATH=/tmp/openshift-client:$PATH
oc version

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME QUAY_REPO TAG_NAME NAME_SPACE NAME_SPACE_RBAC NAME_SPACE_POSTGRES_DB NAME_SPACE_RUNTIME NAME_SPACE_RDS

NAME_SPACE="showcase-ci-nightly-1-4"
NAME_SPACE_RBAC="showcase-rbac-nightly-1-4"
NAME_SPACE_POSTGRES_DB="postgress-external-db-nightly"
NAME_SPACE_RUNTIME="showcase-runtime-1-4"
NAME_SPACE_RDS="showcase-rds-nightly-1-4"

GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"
QUAY_REPO="rhdh/rhdh-hub-rhel9"
TAG_NAME="1.4"

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd rhdh || exit
git checkout "release-1.4" || exit

# Import the image variable set by select-image.sh
if [[ -f "$SHARED_DIR/env_vars" ]]; then
    source "$SHARED_DIR/env_vars"
    echo "🔹 Using image: $RHDH_E2E_RUNNER_IMAGE"
else
    echo "❌ Error: env_vars file not found in SHARED_DIR!"
    exit 1
fi

# Run the main CI job logic
echo "🚀 Running tests with image: $RHDH_E2E_RUNNER_IMAGE"

bash ./.ibm/pipelines/openshift-ci-tests.sh
