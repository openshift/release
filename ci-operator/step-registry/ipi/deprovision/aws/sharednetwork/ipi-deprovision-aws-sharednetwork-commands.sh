#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
pip3 install --user yq
export PATH=~/.local/bin:$PATH

export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred

CONFIG="${SHARED_DIR}/install-config.yaml"

hosted_zone="$(yq -r '.platform.aws.hostedZone' "${CONFIG}")"
echo "Deleting hosted zone: ${hosted_zone}"
aws route53 delete-hosted-zone --id "${hosted_zone}"
