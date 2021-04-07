#!/bin/bash
set -e

mkdir /usr/chectl
cd /usr/chectl


echo "$CHECTL_PARAMS"

echo "$CHECLUSTER_CR_PATCH" > checluster_patch.yaml

cat checluster_patch.yaml

## install chectl

curl "$(curl https://che-incubator.github.io/chectl/download-link/next-linux-x64)" -L -o /tmp/chectl.tar.gz

tar -xvf /tmp/chectl.tar.gz -C /tmp
ln -s /usr/bin/chectl /tmp/chectl/bin/chectl

/tmp/chectl/bin/chectl --version
chectl --version

## run chectl
echo "$CHECTL_PARAMS"
eval echo "$CHECTL_PARAMS"

chectl "$(eval echo "${CHECTL_PARAMS}")"


