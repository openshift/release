#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
cluster_name=${NAMESPACE}-${JOB_NAME_HASH}

out=${SHARED_DIR}/install-config.yaml

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${RELEASE_IMAGE_LATEST}"

ssh_pub_key=$(<"${cluster_profile}/ssh-publickey")
pull_secret=$(<"${cluster_profile}/pull-secret")

cat > "${out}" << EOF
apiVersion: v1
metadata:
  name: ${cluster_name}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF
