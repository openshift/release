#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

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

ansible-playbook test/ansible/run_test.yaml -i test/ansible/inventory.yaml
