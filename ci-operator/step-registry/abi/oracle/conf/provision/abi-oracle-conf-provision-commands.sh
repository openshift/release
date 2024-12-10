#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Downloading mhanss terraform files"

SOURCE_DIR="/tmp/oci-openshift"

mkdir -p $SOURCE_DIR

git clone https://github.com/mhanss/oci-openshift.git $SOURCE_DIR

cd $SOURCE_DIR

echo "Using abi-on-oci branch"

git switch abi-on-oci

echo "Downloading cli tools...."

# Download the installer script:
curl --proto '=https' --tlsv1.2 -fsSL https://github.com/opentofu/opentofu/releases/download/v1.8.7/tofu_1.8.7_linux_amd64.zip -o /tmp/tofu_1.8.7_linux_amd64.zip

mkdir $SHARED_DIR/tofu

unzip /tmp/tofu_1.8.7_linux_amd64.zip -d $SHARED_DIR/tofu/

chmod +x $SHARED_DIR/tofu/tofu

$SHARED_DIR/tofu/tofu --version

echo "Run OpenTofu init"

$SHARED_DIR/tofu/tofu -chdir=$SOURCE_DIR init

echo "Run OpenTofu plan"

$SHARED_DIR/tofu/tofu -chdir=$SOURCE_DIR plan