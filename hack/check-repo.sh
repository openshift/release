#!/bin/bash

# This script runs the check-gh-automation tool locally to check a specific repo's settings

set -o errexit
set -o nounset
set -o pipefail

APPDATA=$(mktemp -d)
trap 'rm -rf "${APPDATA}"' EXIT

# In 'tide' mode we will only check the openshift-merge-bot gh app, otherwise we will check the openshift-ci gh app and the two bots
app_check_mode="$2"
app_name="openshift-ci"
app_secret="openshift-prow-github-app"
bot_args="--bot=openshift-merge-robot --bot=openshift-ci-robot"
if [ "$app_check_mode" == "tide" ]; then
  app_name="openshift-merge-bot"
  app_secret="openshift-merge-bot"
  bot_args="" # Don't check for bots in 'tide' mode
fi

echo "checking $1 using the $app_name app in $app_check_mode mode"

oc --context app.ci --namespace ci extract secret/"$app_secret" --keys appid,cert --to "${APPDATA}" > /dev/null
app_id=$(cat "${APPDATA}/appid")
mkdir "${APPDATA}/prow"
oc --context app.ci --namespace ci extract configmap/config --to "${APPDATA}/prow" > /dev/null
mkdir "${APPDATA}/plugins"
oc --context app.ci --namespace ci extract configmap/plugins --to "${APPDATA}/plugins" > /dev/null

CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}
$CONTAINER_ENGINE login -u=$(oc --context app.ci whoami) -p=$(oc --context app.ci whoami -t) quay-proxy.ci.openshift.org --authfile /tmp/t.c
CONTAINER_ENGINE_OPTS=${CONTAINER_ENGINE_OPTS:- --platform linux/amd64 --authfile /tmp/t.c}
mounts_labels="ro,Z"
if [[ $(uname -s) = "Darwin" && ${CONTAINER_ENGINE} = "podman" ]]; then
  # Darwin (MacOS)
  mounts_labels="ro"
fi
$CONTAINER_ENGINE pull quay-proxy.ci.openshift.org/openshift/ci:ci_check-gh-automation_latest $CONTAINER_ENGINE_OPTS
$CONTAINER_ENGINE run \
    --rm \
    --platform linux/amd64 \
    -v "${APPDATA}:/data:${mounts_labels}" \
    quay-proxy.ci.openshift.org/openshift/ci:ci_check-gh-automation_latest \
    --repo="$1" \
    --app-check-mode="$app_check_mode" \
    --app="$app_name" \
    --config-path="/data/prow/config.yaml" --supplemental-prow-config-dir="/data/prow" \
    --plugin-config="/data/plugins/plugins.yaml" --supplemental-plugin-config-dir="data/plugins" \
    --github-app-id="$app_id" --github-app-private-key-path="/data/cert" \
    $bot_args
