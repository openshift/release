#!/bin/bash

# This script runs the check-gh-automation tool locally to check a specific repo's settings

set -o errexit
set -o nounset
set -o pipefail

APPDATA=$(mktemp -d)
trap 'rm -rf "${APPDATA}"' EXIT

oc --context app.ci --namespace ci extract secret/openshift-prow-github-app --keys appid,cert --to "${APPDATA}"
app_id=$(cat "${APPDATA}/appid")

CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}
$CONTAINER_ENGINE pull registry.ci.openshift.org/ci/check-gh-automation:latest
$CONTAINER_ENGINE run \
    --rm \
    --platform linux/amd64 \
    -v "${APPDATA}/cert":/cert \
    registry.ci.openshift.org/ci/check-gh-automation:latest \
    --repo="$1" \
    --bot=openshift-merge-robot --bot=openshift-ci-robot \
    --github-app-id="$app_id" --github-app-private-key-path="/cert"
