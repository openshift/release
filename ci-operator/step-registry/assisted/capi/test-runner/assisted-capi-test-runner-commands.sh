#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

git config --global user.name "omer-vishlitzky"
git config --global user.email "ovishlit@redhat.com"

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
pip install ruamel.yaml

python scripts/test_runner.py

git add release-candidates.yaml
git commit -m "Update release candidates status after testing" || echo "No changes to commit"
git push origin HEAD:${PULL_BASE_REF}
