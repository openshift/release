#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

WORKDIR=${STEP_WORKDIR:-/tmp}
export PATH=${PATH}:${WORKDIR}
INSTALL_DIR=${WORKDIR}/install-dir
VENV=${WORKDIR}/venv-oci
OCI_BIN=${VENV}/bin/oci

mkdir -vp $INSTALL_DIR

# TODO move install functions to the base image
function upi_conf_provider() {
  echo_date "Installing oci-cli"
  if [[ ! -d $HOME/.oci ]]; then
    mkdir -p $HOME/.oci
    ln -svf $OCI_CONFIG $HOME/.oci/config
  fi
}

function install_yq() {
    echo_date "Checking/installing yq3..."
    if ! [ -x "$(command -v yq3)" ]; then
    wget -qO "${WORKDIR}"/yq3 https://github.com/mikefarah/yq/releases/download/3.4.0/yq_linux_amd64
    chmod u+x "${WORKDIR}"/yq3
    fi
    which yq3
}

function install_terraform() {
    if [[ ! -x "$(command -v terraform)" ]]; then
        echo_date "installing terraform."
        wget -qO "${WORKDIR}"/terraform.zip https://releases.hashicorp.com/terraform/1.6.3/terraform_1.6.3_linux_amd64.zip &&
        unzip terraform.zip
    fi
    which terraform
    terraform version
}

restore_terraform() {
    cp -rvf "$SHARED_DIR"/oci-ocp-upi.tf ${INSTALL_DIR}/
    cp -rvf "$SHARED_DIR"/terraform.* ${INSTALL_DIR}/
    cp -rvf "$SHARED_DIR"/.terraform.* ${INSTALL_DIR}/
    cp -rvf "$SHARED_DIR"/vars-oci-ha_*.tfvars ${INSTALL_DIR}/
}

pushd "$WORKDIR"

install_terraform
install_yq
upi_conf_provider || true

pushd "$INSTALL_DIR"
restore_terraform || true

CLUSTER_NAME=$(yq3 r "${SHARED_DIR}/install-config.yaml" 'metadata.name')
VARS_FILE=${INSTALL_DIR}/vars-oci-ha_${CLUSTER_NAME}.tfvars
source ${SHARED_DIR}/infra_resources.env

echo_date "destroying using terraform"
# ${WORKDIR}/terraform destroy -auto-approve -var-file="${VARS_FILE}" || true
terraform destroy -auto-approve -var-file="${VARS_FILE}" || true

echo_date "deleting bucket using terraform"
if [[ "$(${OCI_BIN} os bucket list --compartment-id "$OCI_COMPARTMENT_ID" | jq -cr ".data[] | select(.name==\"$BUCKET_NAME\").name")"  == "" ]]; then
  echo_date "Creating bucket"
  ${OCI_BIN} os bucket delete --empty --force --name "$BUCKET_NAME" --compartment-id "$OCI_COMPARTMENT_ID"
fi