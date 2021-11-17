#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
export HOME=/tmp

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

# Ensure ignition assets are configured with the correct invoker to track CI jobs.
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"
export TEST_PROVIDER='azure'
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${RELEASE_IMAGE_LATEST}"

dir=/tmp/installer
mkdir "${dir}"
pushd "${dir}"
cp -t "${dir}" \
    "${SHARED_DIR}/install-config.yaml"

if ! pip -V; then
    echo "pip is not installed: installing"
    if python -c "import sys; assert(sys.version_info >= (3,0))"; then
      python -m ensurepip --user || easy_install --user 'pip'
    else
      echo "python < 3, installing pip<21"
      python -m ensurepip --user || easy_install --user 'pip<21'
    fi
fi

echo "Installing python modules: yaml"
python3 -c "import yaml" || pip3 install --user pyyaml

CLUSTER_NAME=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["metadata"]["name"])')
AZURE_REGION=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["platform"]["azure"]["region"])')
SSH_KEY=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["sshKey"])')
BASE_DOMAIN=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["baseDomain"])')
AZURE_AUTH_TENANT_ID=$(jq -r .tenantId ${CLUSTER_PROFILE_DIR}/osServicePrincipal.json)
AZURE_AUTH_CLIENT_SECRET=$(jq -r .clientSecret ${CLUSTER_PROFILE_DIR}/osServicePrincipal.json)
AZURE_AUTH_CLIENT_ID=$(jq -r .clientId ${CLUSTER_PROFILE_DIR}/osServicePrincipal.json)

export CLUSTER_NAME
export AZURE_REGION
export SSH_KEY
export AZURE_AUTH_TENANT_ID
export BASE_DOMAIN
export AZURE_AUTH_CLIENT_SECRET
export AZURE_AUTH_CLIENT_ID

echo $AZURE_AUTH_TENANT_ID >> ${SHARED_DIR}/AZURE_AUTH_TENANT_ID
echo $AZURE_AUTH_CLIENT_SECRET >> ${SHARED_DIR}/AZURE_AUTH_CLIENT_SECRET
echo $AZURE_AUTH_CLIENT_ID >> ${SHARED_DIR}/AZURE_AUTH_CLIENT_ID

echo "Logging in with az"
az login --service-principal -u $AZURE_AUTH_CLIENT_ID -p "$AZURE_AUTH_CLIENT_SECRET" --tenant $AZURE_AUTH_TENANT_ID

# remove workers from the install config so the mco won't try to create them
python3 -c '
import yaml;
path = "install-config.yaml";
data = yaml.full_load(open(path));
data["compute"][0]["replicas"] = 0;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

openshift-install create manifests

# we don't want to create any machine* objects 
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml

RESOURCE_GROUP=$(python3 -c 'import yaml;data = yaml.full_load(open("manifests/cluster-infrastructure-02-config.yml"));print(data["status"]["platformStatus"]["azure"]["resourceGroupName"])')

# typical upi instruction
python3 -c '
import yaml;
path = "manifests/cluster-scheduler-02-config.yml";
data = yaml.full_load(open(path));
data["spec"]["mastersSchedulable"] = False;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

# typical upi instruction
python3 -c '
import yaml;
path = "manifests/cluster-dns-02-config.yml";
data = yaml.full_load(open(path));
del data["spec"]["publicZone"];
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

INFRA_ID=$(python3 -c 'import yaml;data = yaml.full_load(open("manifests/cluster-infrastructure-02-config.yml"));print(data["status"]["infrastructureName"])')
echo "${RESOURCE_GROUP}" > "${SHARED_DIR}/RESOURCE_GROUP_NAME"

openshift-install create ignition-configs &

set +e
wait "$!"
ret="$?"
set -e

cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  exit "$ret"
fi

tar -czf "${SHARED_DIR}/.openshift_install_state.json.tgz" ".openshift_install_state.json"

export SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
RESOURCE_GROUP=$(cat "${SHARED_DIR}/RESOURCE_GROUP_NAME")

echo "Creating resource group ${RESOURCE_GROUP}"
az group create --name "$RESOURCE_GROUP" --location "$AZURE_REGION"

echo "Creating identity"
az identity create -g $RESOURCE_GROUP -n ${INFRA_ID}-identity

KUBECONFIG="${dir}/auth/kubeconfig"
export KUBECONFIG

ACCOUNT_NAME=$(echo ${CLUSTER_NAME}sa | tr -cd '[:alnum:]')

echo "Creating storage account"
az storage account create -g "$RESOURCE_GROUP" --location "$AZURE_REGION" --name "${ACCOUNT_NAME}" --kind Storage --sku Standard_LRS
ACCOUNT_KEY=$(az storage account keys list -g "$RESOURCE_GROUP" --account-name "${ACCOUNT_NAME}" --query "[0].value" -o tsv)

VHD_URL="$(cat /var/lib/openshift-install/rhcos.json | jq -r .azure.url)"

echo "Copying VHD image from ${VHD_URL}"
az storage container create --name vhd --account-name "${ACCOUNT_NAME}" --auth-mode login

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
az storage blob upload --account-name "${INFRA_ID}sa" --account-key "$ACCOUNT_KEY" -c "files" -f "bootstrap.ign" -n "bootstrap.ign"

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
PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-master-pip'] | [0].ipAddress" -o tsv)

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
az deployment group create -g $RESOURCE_GROUP \
  --template-file "06_workers.json" \
  --parameters workerIgnition="$WORKER_IGNITION" \
  --parameters sshKeyData="$SSH_PUB_KEY" \
  --parameters baseName="$INFRA_ID"

echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
openshift-install wait-for bootstrap-complete &

set +e
wait "$!"
ret="$?"
set -e

if [ "$ret" -ne 0 ]; then
  set +e
  # Attempt to gather bootstrap logs.
  echo "$(date -u --rfc-3339=seconds) - Bootstrap failed, attempting to gather bootstrap logs..."
  openshift-install "--dir=${dir}" gather bootstrap --key "${SSH_PRIV_KEY_PATH}" "${GATHER_BOOTSTRAP_ARGS[@]}"
  sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"
  cp log-bundle-*.tar.gz "${ARTIFACT_DIR}"
  set -e
  exit "$ret"
fi

az network nsg rule delete -g "$RESOURCE_GROUP" --nsg-name "${INFRA_ID}"-nsg --name bootstrap_ssh_in
az vm stop -g "$RESOURCE_GROUP" --name "${INFRA_ID}"-bootstrap
az vm deallocate -g "$RESOURCE_GROUP" --name "${INFRA_ID}"-bootstrap
az vm delete -g "$RESOURCE_GROUP" --name "${INFRA_ID}"-bootstrap --yes
az disk delete -g "$RESOURCE_GROUP" --name "${INFRA_ID}"-bootstrap_OSDisk --no-wait --yes
az network nic delete -g "$RESOURCE_GROUP" --name "${INFRA_ID}"-bootstrap-nic --no-wait
az storage blob delete --account-key "$ACCOUNT_KEY" --account-name "${INFRA_ID}sa" --container-name files --name bootstrap.ign
az network public-ip delete -g "$RESOURCE_GROUP" --name "${INFRA_ID}"-bootstrap-ssh-pip

echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
function approve_csrs() {
  while [[ ! -f /tmp/install-complete ]]; do
      # even if oc get csr fails continue
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
  done
}
approve_csrs &

## Wait for the default-router to have an external ip...(and not <pending>)
  echo "$(date -u --rfc-3339=seconds) - Waiting for the default-router to have an external ip..."
  set +e
  ROUTER_IP="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
  while [[ "$ROUTER_IP" == "" || "$ROUTER_IP" == "<pending>" ]]; do
    sleep 10;
    ROUTER_IP="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
  done
  set -e

az network dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $ROUTER_IP --ttl 300

echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."
openshift-install --dir="${dir}" wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

set +e
wait "$!"
ret="$?"
set -e

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  exit "$ret"
fi

cp -t "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig"
popd
touch /tmp/install-complete
