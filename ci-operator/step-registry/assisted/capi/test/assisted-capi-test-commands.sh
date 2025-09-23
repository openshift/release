#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if [[ -z "${TEST_TARGET:-}" ]]; then
  echo "ERROR: TEST_TARGET environment variable must be set"
  echo "Valid options are: \"e2e\" or \"versions-management-test\""
  exit 1
fi

SSH_KEY_FILE="${CLUSTER_PROFILE_DIR}/packet-private-ssh-key"
SSH_AUTHORIZED_KEY="$(cat ${CLUSTER_PROFILE_DIR}/packet-public-ssh-key)"
REMOTE_HOST=$(cat "${SHARED_DIR}/server-ip")
PULLSECRET=$(cat $CLUSTER_PROFILE_DIR/pull-secret | base64 -w0)
GOCACHE=/tmp
HOME=/tmp
DIST_DIR=/tmp/dist
CONTAINER_TAG=local
export SSH_KEY_FILE
export SSH_AUTHORIZED_KEY
export REMOTE_HOST
export PULLSECRET
export GOCACHE
export HOME
export DIST_DIR
export CONTAINER_TAG

make generate && make manifests && make build-installer

if [[ "${TEST_TARGET}" == "snapshots-test" ]]; then
    GITHUB_APP_ID=$(cat "/var/run/vault/capi-versioning-app-credentials/github_app_id")
    GITHUB_APP_INSTALLATION_ID=$(cat "/var/run/vault/capi-versioning-app-credentials/github_app_installation_id")
    GITHUB_APP_PRIVATE_KEY_PATH="/var/run/vault/capi-versioning-app-credentials/github_app_private_key.pem"
    export GITHUB_APP_ID
    export GITHUB_APP_INSTALLATION_ID
    export GITHUB_APP_PRIVATE_KEY_PATH
    if [[ -z "${GITHUB_APP_ID:-}" || -z "${GITHUB_APP_INSTALLATION_ID:-}" || -z "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]]; then
        echo "ERROR: GitHub App environment variables must be set for ansible-test-runner"
        echo "Required: GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_PATH"
        exit 1
    fi
fi
ANSIBLE_REMOTE_TEMP=/tmp/.ansible-remote ANSIBLE_HOME=/tmp/.ansible ANSIBLE_LOCAL_TEMP=/tmp/.ansible.tmp XDG_CACHE_HOME=/tmp/.cache ANSIBLE_CACHE_PLUGIN_CONNECTION=/tmp/.ansible-cache make "$TEST_TARGET" DRY_RUN=${DRY_RUN:-false}
