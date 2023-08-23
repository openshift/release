#!/bin/bash

set -o pipefail

echo "Setting the BREW_DOCKERCONFIGJSON"

# add brew pull secret 
BREW_DOCKERCONFIGJSON=${BREW_DOCKERCONFIGJSON:-'/var/run/brew-pullsecret/.dockerconfigjson'}

echo "The BREW_DOCKERCONFIGJSON variable is set"

echo "Copying the BREW_DOCKERCONFIGJSON variable to ${SHARED_DIR}/pull-secret-build-farm.json"

# copy brew pull secret to HostedCluster
# >> appends
echo "$BREW_DOCKERCONFIGJSON" >> ${SHARED_DIR}/pull-secret-build-farm.json

echo "BREW_DOCKERCONFIGJSON has been copied"