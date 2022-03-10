#!/bin/bash
set -euo pipefail

INSTALL_STAGE="initial"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save install status for must-gather to generate junit
trap 'echo "$? $INSTALL_STAGE" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.
export PATH=/tmp:${PATH}

function backoff() {
    local attempt=0
    local failed=0
    while true; do
        "$@" && failed=0 || failed=1
        if [[ $failed -eq 0 ]]; then
            break
        fi
        attempt=$(( attempt + 1 ))
        if [[ $attempt -gt 5 ]]; then
            break
        fi
        echo "command failed, retrying in $(( 2 ** $attempt )) seconds"
        sleep $(( 2 ** $attempt ))
    done
    return $failed
}

GATHER_BOOTSTRAP_ARGS=

function gather_bootstrap_and_fail() {
  if test -n "${GATHER_BOOTSTRAP_ARGS}"; then
    openshift-install --dir=${ARTIFACT_DIR}/installer gather bootstrap --key "${SSH_PRIVATE_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi

  return 1
}

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"
export TEST_PROVIDER='azure'

cp "$(command -v openshift-install)" /tmp
mkdir ${ARTIFACT_DIR}/installer

echo "Installing from release ${RELEASE_IMAGE_LATEST}"
OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${RELEASE_IMAGE_LATEST}"
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE

cp ${SHARED_DIR}/install-config.yaml ${ARTIFACT_DIR}/installer/install-config.yaml
export PATH=${HOME}/.local/bin:${PATH}
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
export AZURE_AUTH_LOCATION

pushd ${ARTIFACT_DIR}/installer
python3 -c "import yaml" || pip3 install --user pyyaml

CLUSTER_NAME=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["metadata"]["name"])')
BASE_DOMAIN=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["baseDomain"])')
AZURE_REGION=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["platform"]["azure"]["region"])')
BASE_DOMAIN_RESOURCE_GROUP=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["platform"]["azure"]["baseDomainResourceGroupName"])')
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
export CLUSTER_NAME
export BASE_DOMAIN

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
echo "Creating manifests"
openshift-install --dir=${ARTIFACT_DIR}/installer create manifests

echo "Editing manifests"
sed -i '/^  channel:/d' manifests/cvo-overrides.yaml
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" manifests/cluster-scheduler-02-config.yml
sed -i "/publicZone/,+1d" manifests/cluster-dns-02-config.yml
sed -i "/privateZone/,+1d" manifests/cluster-dns-02-config.yml

popd

echo "Creating ignition configs"
openshift-install --dir=${ARTIFACT_DIR}/installer create ignition-configs &
wait "$!"

cp ${ARTIFACT_DIR}/installer/bootstrap.ign ${SHARED_DIR}
BOOTSTRAP_URI="https://${JOB_NAME_SAFE}-bootstrap-exporter-${NAMESPACE}.svc.ci.openshift.org/bootstrap.ign"
export BOOTSTRAP_URI
# begin bootstrapping

mkdir -p /tmp/azure

# Copy sample UPI files
cp -r /var/lib/openshift-install/upi/azure/* /tmp/azure

echo "az version:"
az version

echo "Logging in with az"
AZURE_AUTH_CLIENT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .clientId)
AZURE_AUTH_CLIENT_SECRET=$(cat $AZURE_AUTH_LOCATION | jq -r .clientSecret)
AZURE_AUTH_TENANT_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .tenantId)
AZURE_SUBSCRIPTION_ID=$(cat $AZURE_AUTH_LOCATION | jq -r .subscriptionId)
az login --service-principal -u $AZURE_AUTH_CLIENT_ID -p "$AZURE_AUTH_CLIENT_SECRET" --tenant $AZURE_AUTH_TENANT_ID --output none
az account set --subscription ${AZURE_SUBSCRIPTION_ID}

echo ${AZURE_SUBSCRIPTION_ID} >> ${SHARED_DIR}/AZURE_SUBSCRIPTION_ID
echo ${AZURE_AUTH_CLIENT_ID} >> ${SHARED_DIR}/AZURE_AUTH_CLIENT_ID
echo ${AZURE_AUTH_CLIENT_SECRET} >> ${SHARED_DIR}/AZURE_AUTH_CLIENT_SECRET
echo ${AZURE_AUTH_TENANT_ID} >> ${SHARED_DIR}/AZURE_AUTH_TENANT_ID

INFRA_ID="$(jq -r .infraID ${ARTIFACT_DIR}/installer/metadata.json)"
RESOURCE_GROUP="${INFRA_ID}-rg"
echo "Infra ID: ${INFRA_ID}"

echo "Creating resource group ${RESOURCE_GROUP}"
az group create --name $RESOURCE_GROUP --location $AZURE_REGION

echo "Creating identity"
az identity create -g $RESOURCE_GROUP -n ${INFRA_ID}-identity

ACCOUNT_NAME=$(echo ${CLUSTER_NAME}sa | tr -cd '[:alnum:]')

echo "Creating storage account"
az storage account create -g $RESOURCE_GROUP --location $AZURE_REGION --name $ACCOUNT_NAME --kind Storage --sku Standard_LRS
ACCOUNT_KEY=$(az storage account keys list -g $RESOURCE_GROUP --account-name $ACCOUNT_NAME --query "[0].value" -o tsv)

if openshift-install coreos print-stream-json 2>/tmp/err.txt >/tmp/coreos.json; then
  VHD_URL="$(jq -r '.architectures.x86_64."rhel-coreos-extensions"."azure-disk".url' /tmp/coreos.json)"
else
  VHD_URL="$(jq -r .azure.url /var/lib/openshift-install/rhcos.json)"
fi

echo "Copying VHD image from ${VHD_URL}"
az storage container create --name vhd --account-name $ACCOUNT_NAME --auth-mode login

status="false"
while [ "$status" == "false" ]
do
  status=$(az storage container exists --account-name $ACCOUNT_NAME --name vhd --auth-mode login -o tsv --query exists)
done

az storage blob copy start --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY --destination-container vhd --destination-blob "rhcos.vhd" --source-uri "$VHD_URL"
status="false"
while [ "$status" == "false" ]
do
  status=$(az storage blob exists --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY --container-name vhd --name "rhcos.vhd" -o tsv --query exists)
done

status="pending"
while [ "$status" == "pending" ]
do
  status=$(az storage blob show --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY --container-name vhd --name "rhcos.vhd" -o tsv --query properties.copy.status)
done
if [[ "$status" != "success" ]]; then
  echo "Error copying VHD image ${VHD_URL}"
  exit 1
fi

echo "Uploading bootstrap.ign"
az storage container create --name files --account-name $ACCOUNT_NAME --public-access blob
az storage blob upload --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY -c "files" -f "${ARTIFACT_DIR}/installer/bootstrap.ign" -n "bootstrap.ign"

echo "Creating private DNS zone"
az network private-dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}

PRINCIPAL_ID=$(az identity show -g $RESOURCE_GROUP -n ${INFRA_ID}-identity --query principalId --out tsv)
echo "Assigning 'Contributor' role to principal ID ${PRINCIPAL_ID}"
RESOURCE_GROUP_ID=$(az group show -g $RESOURCE_GROUP --query id --out tsv)
az role assignment create --assignee "$PRINCIPAL_ID" --role 'Contributor' --scope "$RESOURCE_GROUP_ID"

pushd /tmp/azure

echo "Deploying 01_vnet"
az deployment group create -g $RESOURCE_GROUP \
  --template-file "01_vnet.json" \
  --parameters baseName="$INFRA_ID"

echo "Linking VNet to private DNS zone"
az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${INFRA_ID}-network-link -v "${INFRA_ID}-vnet" -e false

echo "Deploying 02_storage"
VHD_BLOB_URL=$(az storage blob url --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY -c vhd -n "rhcos.vhd" -o tsv)
az deployment group create -g $RESOURCE_GROUP \
  --template-file "02_storage.json" \
  --parameters vhdBlobURL="${VHD_BLOB_URL}" \
  --parameters baseName="$INFRA_ID"

echo "Deploying 03_infra"
az deployment group create -g $RESOURCE_GROUP \
  --template-file "03_infra.json" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
  --parameters baseName="$INFRA_ID"

set +e
PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-master-pip'] | [0].ipAddress" -o tsv)
while [[ "$PUBLIC_IP" == "" ]]; do
  sleep 10;
  PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-master-pip'] | [0].ipAddress" -o tsv)
done
set -e

echo "Creating 'api' record in public zone for IP ${PUBLIC_IP}"
az network dns record-set a add-record -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} -n api.${CLUSTER_NAME} -a $PUBLIC_IP --ttl 60

echo "Deploying 04_bootstrap"
BOOTSTRAP_URL=$(az storage blob url --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY -c "files" -n "bootstrap.ign" -o tsv)
IGNITION_VERSION=$(jq -r .ignition.version ${ARTIFACT_DIR}/installer/bootstrap.ign)
BOOTSTRAP_IGNITION=$(jq -rcnM --arg v "${IGNITION_VERSION}" --arg url $BOOTSTRAP_URL '{ignition:{version:$v,config:{replace:{source:$url}}}}' | base64 -w0)
az deployment group create -g $RESOURCE_GROUP \
  --template-file "04_bootstrap.json" \
  --parameters bootstrapIgnition="$BOOTSTRAP_IGNITION" \
  --parameters sshKeyData="$SSH_PUB_KEY" \
  --parameters baseName="$INFRA_ID"

BOOTSTRAP_PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-bootstrap-ssh-pip'] | [0].ipAddress" -o tsv)
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --bootstrap ${BOOTSTRAP_PUBLIC_IP}"

echo "Deploying 05_masters"
MASTER_IGNITION=$(cat ${ARTIFACT_DIR}/installer/master.ign | base64 -w0)
az deployment group create -g $RESOURCE_GROUP \
  --template-file "05_masters.json" \
  --parameters masterIgnition="$MASTER_IGNITION" \
  --parameters sshKeyData="$SSH_PUB_KEY" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
  --parameters baseName="$INFRA_ID"

MASTER0_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-0-nic --name pipConfig --query "privateIpAddress" -o tsv)
MASTER1_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-1-nic --name pipConfig --query "privateIpAddress" -o tsv)
MASTER2_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-2-nic --name pipConfig --query "privateIpAddress" -o tsv)
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --master ${MASTER0_IP} --master ${MASTER1_IP} --master ${MASTER2_IP}"

echo "Deploying 06_workers"
WORKER_IGNITION=$(cat ${ARTIFACT_DIR}/installer/worker.ign | base64 -w0)
export WORKER_IGNITION
az deployment group create -g $RESOURCE_GROUP \
  --template-file "06_workers.json" \
  --parameters workerIgnition="$WORKER_IGNITION" \
  --parameters sshKeyData="$SSH_PUB_KEY" \
  --parameters baseName="$INFRA_ID"

popd
echo "Waiting for bootstrap to complete"
openshift-install --dir=${ARTIFACT_DIR}/installer wait-for bootstrap-complete &
wait "$!" || gather_bootstrap_and_fail

INSTALL_STAGE="bootstrap_successful"
echo "Bootstrap complete, destroying bootstrap resources"
az network nsg rule delete -g $RESOURCE_GROUP --nsg-name ${INFRA_ID}-nsg --name bootstrap_ssh_in
az vm stop -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap
az vm deallocate -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap
az vm delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap --yes
az disk delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap_OSDisk --no-wait --yes
az network nic delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap-nic --no-wait
az storage blob delete --account-key $ACCOUNT_KEY --account-name $ACCOUNT_NAME --container-name files --name bootstrap.ign
az network public-ip delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap-ssh-pip

echo "Adding ingress DNS records"

export KUBECONFIG=${ARTIFACT_DIR}/installer/auth/kubeconfig

set +e
public_ip_router="<pending>"
while [[ $public_ip_router =~ "pending" ]]
do
  public_ip_router=$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')
  echo $public_ip_router
done
set -e

az network dns record-set a add-record -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} -n *.apps.${CLUSTER_NAME} -a $public_ip_router --ttl 300

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $public_ip_router

function approve_csrs() {
  oc version --client
  while true; do
    if [[ ! -f /tmp/install-complete ]]; then
      # even if oc get csr fails continue
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
      continue
    else
      break
    fi
  done
}

echo "Approving pending CSRs"
export KUBECONFIG=${ARTIFACT_DIR}/installer/auth/kubeconfig
approve_csrs &

set +x
echo "Completing UPI setup"
openshift-install --dir=${ARTIFACT_DIR}/installer wait-for install-complete 2>&1 | grep --line-buffered -v password &
wait "$!"

INSTALL_STAGE="cluster_creation_successful"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"
# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' ${ARTIFACT_DIR}/installer/.openshift_install.log
cp "${ARTIFACT_DIR}/installer/metadata.json" "${SHARED_DIR}"
cp "${ARTIFACT_DIR}/installer/auth/kubeconfig" "${SHARED_DIR}"
touch /tmp/install-complete