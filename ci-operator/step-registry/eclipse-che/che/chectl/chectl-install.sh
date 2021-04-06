#!/bin/bash
set -e

echo "$CHECLUSTER_CR_PATCH"

## install chectl

curl "$(curl https://che-incubator.github.io/chectl/download-link/next-linux-x64)" -L -o chectl.tar.gz

tar -xvf chectl.tar.gz

mv chectl /tmp
/tmp/bin/chectl --version

## run chectl

/tmp/chectl/bin/chectl server:deploy --telemetry=off -p openshift


