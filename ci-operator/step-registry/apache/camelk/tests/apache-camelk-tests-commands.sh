#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Each key/value pair in a Vault secret is given a file in the mount_path defined. 
# This files name is the key value and the contents is a single clear-text line containing the value.
# See the Secrets Guide for more information.

export NAMESPACE=$CAMELK_NAMESPACE
echo "Running camelk interop tests"

docker run --user 1000:1000 -e KUBECONFIG=/data/auth/kubeconfig/config quay.io/fuse_qe/camel-k-e2e:latest


# This line is using the cat command to set the contents of a credential file to a variable.
#CREDENTIAL=$(cat /tmp/secrets/credentials/password)
