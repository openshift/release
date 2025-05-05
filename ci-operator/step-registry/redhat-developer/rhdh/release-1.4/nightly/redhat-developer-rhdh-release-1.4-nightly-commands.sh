#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

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

bash ./.ibm/pipelines/openshift-ci-tests.sh
