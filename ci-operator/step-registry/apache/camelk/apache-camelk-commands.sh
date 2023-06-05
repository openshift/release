#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Each key/value pair in a Vault secret is given a file in the mount_path defined. 
# This files name is the key value and the contents is a single clear-text line containing the value.
# See the Secrets Guide for more information.

export NAMESPACE=$DEPL_PROJECT_NAME
echo "Running camelk interop tests"

# This line is using the cat command to set the contents of a credential file to a variable.
#CREDENTIAL=$(cat /tmp/secrets/credentials/password)
