#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# create windows_instances.data
echo "data:" > "${SHARED_DIR}"/windows_instances.data

# look for Windows instances files in the shared dir.
# the pattern is:
#   <address>_windows_instance.txt
# where, <address> is the network address used to SSH into the instance, it can be an IPv4 or a DNS name.
# See https://github.com/openshift/windows-machine-config-operator#adding-instances
for f in "${SHARED_DIR}"/*_windows_instance.txt;
do
  if test -f "${f}"
    then
      echo "$(date -u --rfc-3339=seconds) - Processing Windows instance file: ${f}"
      # parse instance's address from filename
      instance_address=$(basename "${f}" "_windows_instance.txt")
      # load instance's information from file content
      instance_info=$(<"${f}")
      # append current Windows instance information
      cat >> "${SHARED_DIR}/windows_instances.data" << EOF
  ${instance_address}: |-
    ${instance_info}
EOF
  fi
done

WINDOWS_INSTANCES_DATA=$(<"${SHARED_DIR}"/windows_instances.data)
export WINDOWS_INSTANCES_DATA
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

make run-ci-e2e-byoh-test
