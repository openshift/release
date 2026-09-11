#!/bin/bash
 
set -o nounset
set -o errexit
set -o pipefail
 
# find and use the first Windows instance file in the shared dir
# the pattern is:
#   <address>_windows_instance.txt
# where, <address> is the network address used to SSH into the instance, it can be an IPv4 or a DNS name.
# See https://github.com/openshift/windows-machine-config-operator#adding-instances
instance_files=$(ls ${SHARED_DIR}/*_windows_instance.txt)
instance_file=${instance_files[0]}
if ! test -f "${instance_file}"; then
    echo "unable to find Windows instance to use"
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Processing Windows instance file: ${instance_file}"
# parse instance's address from filename
INSTANCE_ADDRESS=$(basename "${instance_file}" "_windows_instance.txt")
export INSTANCE_ADDRESS
# grab user to SSH as from the file's content
INSTANCE_USERNAME=$(cat $instance_file | sed 's/username=\(\w*\)/\1/')
export INSTANCE_USERNAME
# export key required to SSH into the instance
export KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

make wicd-unit
