#!/bin/bash
#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

export WORKDIR=${STEP_WORKDIR:-/tmp}
export PATH=${WORKDIR}:${PATH}
export INSTALL_DIR=${WORKDIR}/install-dir

export VENV=${WORKDIR}/venv-oci
export OCI_BIN=${VENV}/bin/oci

TF_PLAN_NAME=${INSTALL_DIR}/oci-ocp-upi.tf
OCI_CCM_NAMESPACE=oci-cloud-controller-manager

save_terraform_assets() {
  cp -vf "${INSTALL_DIR}"/oci-ocp-upi.tf "$SHARED_DIR"/ || true
  cp -vf "${INSTALL_DIR}"/terraform.* "$SHARED_DIR"/ || true
  cp -vf "${INSTALL_DIR}"/.terraform.* "$SHARED_DIR"/ || true
  cp -vf "${INSTALL_DIR}"/"vars-oci-ha_${CLUSTER_NAME}.tfvars" "$SHARED_DIR"/ || true
}
trap 'save_terraform_assets' EXIT TERM INT

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

function save_resource_env() {
  echo "$1=$2" >> "${SHARED_DIR}"/infra_resources.env
}

echo "======================="
echo "Installing dependencies"
echo "======================="

mkdir -vp "$INSTALL_DIR"
pushd "${WORKDIR}" || true

# TODO move install functions to the base image
function install_yq() {
    echo_date "Checking/installing yq3..."
    if ! [ -x "$(command -v yq3)" ]; then
      wget -qO "${WORKDIR}"/yq3 https://github.com/mikefarah/yq/releases/download/3.4.0/yq_linux_amd64
      chmod u+x "${WORKDIR}"/yq3
    fi
    which yq3
}

function install_terraform() {
    # if [[ ! -x "$(command -v terraform)" ]]; then
        echo_date "installing terraform."
        wget -qO "${WORKDIR}"/terraform.zip https://releases.hashicorp.com/terraform/1.6.3/terraform_1.6.3_linux_amd64.zip &&
        unzip terraform.zip
    # fi
    which terraform
    terraform version
}

function upi_conf_provider() {
  echo_date "Installing oci-cli"
  if [[ ! -d "$HOME"/.oci ]]; then
    mkdir -p "$HOME"/.oci
  fi
  ln -svf "$OCI_CONFIG" "$HOME"/.oci/config
  python3 -m venv "${WORKDIR}"/venv-oci && source "${WORKDIR}"/venv-oci/bin/activate
  "${VENV}"/bin/pip install -U pip > /dev/null
  "${VENV}"/bin/pip install -U oci-cli > /dev/null
  $OCI_BIN setup repair-file-permissions --file "$HOME"/.oci/config || true
  export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
}

install_yq
install_terraform

echo_date "download oci client"
upi_conf_provider || true

echo_date "download terraform plan"
wget -qO "${TF_PLAN_NAME}" https://raw.githubusercontent.com/mtulio/oci-openshift/ocp-upi/infrastructure.tf

source ${OCI_COMPARTMENTS_ENV}

BASE_DOMAIN=$(yq3 r "${SHARED_DIR}/install-config.yaml" 'baseDomain')
CLUSTER_NAME=$(yq3 r "${SHARED_DIR}/install-config.yaml" 'metadata.name')
VARS_FILE=${INSTALL_DIR}/vars-oci-ha_${CLUSTER_NAME}.tfvars

echo_date "Checking the infra Bucket"
BUCKET_NAME="${CLUSTER_NAME}-infra"
if [[ "$(${OCI_BIN} os bucket list --compartment-id "$OCI_COMPARTMENT_ID" | jq -cr ".data[] | select(.name==\"$BUCKET_NAME\").name")"  == "" ]]; then
  echo_date "Creating bucket"
  ${OCI_BIN} os bucket create --name $BUCKET_NAME --compartment-id "$OCI_COMPARTMENT_ID"
fi
save_resource_env "BUCKET_NAME" "${BUCKET_NAME}"
save_resource_env "OCI_COMPARTMENT_ID" "${OCI_COMPARTMENT_ID}"

echo "==============================="
echo "CREATING STACK: COMPUTE / IMAGE"
echo "==============================="

IMAGE_NAME=$(basename "$(openshift-install coreos print-stream-json | jq -r '.architectures["x86_64"].artifacts["openstack"].formats["qcow2.gz"].disk.location')")

if [[ ! -f "${IMAGE_NAME}" ]]; then
  echo_date "Downloading RHCOS"
  wget -q "$(openshift-install coreos print-stream-json | jq -r '.architectures["x86_64"].artifacts["openstack"].formats["qcow2.gz"].disk.location')"
fi

if [[ "$(${OCI_BIN} os object list -bn $BUCKET_NAME --prefix images/"${IMAGE_NAME}" | jq -r '.data | length')"  -eq 0 ]]; then
  echo_date "Uploading to bucket"
  ${OCI_BIN} os object put -bn $BUCKET_NAME --name images/"${IMAGE_NAME}" --file "${IMAGE_NAME}"
else
  echo_date "image already exists, ignoring upload to bucket"
fi

echo_date "creating preauth for RHCOS"
EXPIRES_TIME=$(date -d '+1 hour' --rfc-3339=seconds)
BUCKET_IMAGE_URL=$(${OCI_BIN} os preauth-request create --name "${IMAGE_NAME}" \
    -bn "$BUCKET_NAME" -on images/"${IMAGE_NAME}"\
    --access-type ObjectRead  --time-expires "$EXPIRES_TIME" \
    | jq -r '.data["full-path"]')

## BOOSTRAP
echo_date "Uploading bootstrap.ign"
${OCI_BIN} os object put --force -bn $BUCKET_NAME --name bootstrap-"${CLUSTER_NAME}".ign \
    --file "$SHARED_DIR"/bootstrap.ign

echo_date "creating pre-auth for bootstrap.ign"
EXPIRES_TIME=$(date -d '+1 hour' --rfc-3339=seconds)
IGN_BOOTSTRAP_URL=$(${OCI_BIN} os preauth-request create --name bootstrap-"${CLUSTER_NAME}" \
    -bn "$BUCKET_NAME" -on bootstrap-"${CLUSTER_NAME}".ign \
    --access-type ObjectRead  --time-expires "$EXPIRES_TIME" \
    | jq -r '.data["full-path"]')

echo_date "creating bootstrap iginition file to fetch data from source URL (bucket)"
cat <<EOF > "${INSTALL_DIR}"/bootstrap-upi.ign
{
  "ignition": {
    "config": {
      "replace": {
        "source": "${IGN_BOOTSTRAP_URL}"
      }
    },
    "version": "3.1.0"
  }
}
EOF

pushd "${INSTALL_DIR}"

echo_date "terraform init"
terraform init

TENANCY_ID=$(${OCI_BIN} iam compartment list \
  --all \
  --compartment-id-in-subtree true \
  --access-level ACCESSIBLE \
  --include-root \
  --raw-output \
  --query "data[?contains(\"id\",'tenancy')].id | [0]")

#home_region="us-ashburn-1"
cat <<EOF > "${VARS_FILE}"
home_region="us-sanjose-1"
zone_dns="${BASE_DOMAIN}"
tenancy_ocid="${TENANCY_ID}"
compartment_ocid="${OCI_COMPARTMENT_ID}"
compartment_dns_ocid="${OCI_COMPARTMENT_ID_DNS}"
cluster_name="${CLUSTER_NAME}"
openshift_image_source_uri="${BUCKET_IMAGE_URL}"
create_bootstrap=true
ccm_namespace="${OCI_CCM_NAMESPACE}"
ccm_config_output_filename="ccm-01-secret.yaml"
EOF

cp -v "$SHARED_DIR"/{master,worker}.ign "${INSTALL_DIR}"/
terraform plan -var-file="${VARS_FILE}"
terraform apply -auto-approve -var-file="${VARS_FILE}"

cp -v "${INSTALL_DIR}"/ccm-01-secret.yaml "$SHARED_DIR"/ccm-01-secret.yaml
echo "ccm-01-secret.yaml" >> "${SHARED_DIR}"/ccm-manifests.txt

save_resource_env "INSTANCE_CONFIG_ID" "$(terraform output -raw openshift_bootstrap_config_id || true)"
save_resource_env "INSTANCE_POOL_ID" "$(terraform output -raw openshift_bootstrap_pool_id || true)"

save_terraform_assets || true
