#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

SECRET_DIR="/tmp/vault/powervs-rhr-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/ODH_POWER_SSH_KEY"
HOME=/tmp
SSH_KEY_PATH="$HOME/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR"

# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

POWERVS_IP=odh-power-node.ecosystemci.cis.ibm.net

REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"
if [[ ! -r "$REGISTRY_TOKEN_FILE" ]]; then
    log "ERROR Registry secret file not found: $REGISTRY_TOKEN_FILE"
    exit 1
fi

log "INFO Copying secret file ${REGISTRY_TOKEN_FILE}"
# for docker
#cat ${REGISTRY_TOKEN_FILE} | ssh $SSH_ARGS root@$POWERVS_IP "mkdir -p /root/.docker; cat > /root/.docker/config.json"
# for podman
#cat ${REGISTRY_TOKEN_FILE} | ssh $SSH_ARGS root@$POWERVS_IP "mkdir -p /root/.podman/containers; cat > /root/.podman/containers/auth.json"


export REPO_OWNER=opendatahub-io
export REPO_NAME=opendatahub-operator
export PULL_BASE_REF=incubation
export PULL_NUMBER=1047
export DESTINATION_IMAGE_REF=quay.io/shafi_rhel/opendatahub-operator:incubation-pr-$PULL_NUMBER

# set build any env to be set on Power VM
cat <<EOF > $HOME/env_vars.sh
REPO_OWNER=${REPO_OWNER:-UNKNOWN}
REPO_NAME=${REPO_NAME:-UNKNOWN}
PULL_BASE_REF=${PULL_BASE_REF:-UNKNOWN}
PULL_BASE_SHA=${PULL_BASE_SHA:-UNKNOWN}
PULL_NUMBER=${PULL_NUMBER:-UNKNOWN}
PULL_PULL_SHA=${PULL_PULL_SHA:-UNKNOWN}
PULL_REFS=${PULL_REFS:-UNKNOWN}
REGISTRY_HOST=${REGISTRY_HOST:-UNKNOWN}
REGISTRY_ORG=${REGISTRY_ORG:-UNKNOWN}
IMAGE_REPO=${IMAGE_REPO:-UNKNOWN}
IMAGE_TAG=${IMAGE_TAG:-UNKNOWN}
SOURCE_IMAGE_REF=${SOURCE_IMAGE_REF:-UNKNOWN}
DESTINATION_REGISTRY_REPO=${DESTINATION_REGISTRY_REPO:-UNKNOWN}
DESTINATION_IMAGE_REF=${DESTINATION_IMAGE_REF:-UNKNOWN}
JOB_NAME=${JOB_NAME:-UNKNOWN}
JOB_TYPE=${JOB_TYPE:-UNKNOWN}
PROW_JOB_ID=${PROW_JOB_ID:-UNKNOWN}
RELEASE_VERSION=${RELEASE_VERSION:-UNKNOWN}

BUILD_DIR=test_build
EOF

cat $HOME/env_vars.sh | ssh $SSH_ARGS root@$POWERVS_IP "cat > /root/env_vars.sh"

timeout --kill-after 10m 60m ssh $SSH_ARGS root@$POWERVS_IP bash -x - << EOF
        source env_vars.sh

        # for manifests. quay.io does not support format=oci (ref: https://github.com/containers/podman/issues/8353)
        export BUILDAH_FORMAT=docker

        # pull & retag
        docker pull \$DESTINATION_IMAGE_REF-ppc64le

        docker pull quay.io/opendatahub/opendatahub-operator:latest
        AMD=\$(docker inspect quay.io/opendatahub/opendatahub-operator:latest | jq '.[0].Id' | tr -d '"' | cut -d: -f2)
        docker tag \$AMD \$DESTINATION_IMAGE_REF-amd64
        docker push \$DESTINATION_IMAGE_REF-amd64

        docker manifest create \$DESTINATION_IMAGE_REF \$DESTINATION_IMAGE_REF-amd64 \$DESTINATION_IMAGE_REF-ppc64le
        docker manifest push \$DESTINATION_IMAGE_REF

EOF

