#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

if [ "$COMMUNITY" == "true" ]; then
  #!/bin/bash
  # yq is needed to transform fields in the community bundle
  curl -L https://github.com/mikefarah/yq/releases/download/v4.13.5/yq_linux_amd64 -o /tmp/yq
  chmod +x /tmp/yq
  PATH=${PATH}:/tmp
  make community-bundle
fi

make run-ci-e2e-test
