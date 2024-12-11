#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

CLUSTER_NAME="abi-qe-${NAMESPACE}"
BASE_DOMAIN="$CLUSTER_NAME.oci-rhelcert.edge-sro.rhecoeng.com"

TENANCY_OCID=$(</var/run/oci-secret-tenancy/tenancy_ocid)
COMPARTMENT=$(</var/run/oci-secret-compartment/compartment)

echo "Downloading OpenTofu...."

# Download the installer script:
curl --proto '=https' --tlsv1.2 -fsSL https://github.com/opentofu/opentofu/releases/download/v1.8.7/tofu_1.8.7_linux_amd64.zip -o /tmp/tofu_1.8.7_linux_amd64.zip

mkdir $SHARED_DIR/tofu

unzip /tmp/tofu_1.8.7_linux_amd64.zip -d $SHARED_DIR/tofu/

chmod +x $SHARED_DIR/tofu/tofu

$SHARED_DIR/tofu/tofu --version

echo "Downloading mhanss terraform files"

SOURCE_DIR="/tmp/oci-openshift"

mkdir -p $SOURCE_DIR

git clone https://github.com/mhanss/oci-openshift.git $SOURCE_DIR

cd $SOURCE_DIR

echo "Using abi-on-oci branch"

git switch abi-on-oci

echo "Run OpenTofu init"

$SHARED_DIR/tofu/tofu -chdir=$SOURCE_DIR/infrastructure init

echo "Run OpenTofu plan"

$SHARED_DIR/tofu/tofu -chdir=$SOURCE_DIR/infrastructure plan \
      -var="cluster_name=${CLUSTER_NAME}" \
      -var="compartment_ocid=${COMPARTMENT}" \
      -var="tenancy_ocid=${TENANCY_OCID}" \
      -var="zone_dns=${BASE_DOMAIN}"