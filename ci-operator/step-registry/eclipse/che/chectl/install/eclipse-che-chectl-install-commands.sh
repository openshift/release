#!/bin/bash
set -e

echo "id:"
id 
echo "pwd:"
pwd
echo "CI_CHE_OPERATOR_IMAGE:"
echo $CI_CHE_OPERATOR_IMAGE

mkdir /tmp/workspace
cd /tmp/workspace


echo "$CHECTL_PARAMS"

echo "$CHECLUSTER_CR_PATCH" > checluster_patch.yaml

cat checluster_patch.yaml

## install chectl

curl "$(curl https://che-incubator.github.io/chectl/download-link/next-linux-x64)" -L -o /tmp/chectl.tar.gz

tar -xf /tmp/chectl.tar.gz -C /tmp

/tmp/chectl/bin/chectl --version

## run chectl
echo "$CHECTL_PARAMS"
eval echo "$CHECTL_PARAMS"

/tmp/chectl/bin/chectl "$(eval echo "${CHECTL_PARAMS}")"


