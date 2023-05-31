#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM
export HOME=/tmp

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

# Ensure ignition assets are configured with the correct invoker to track CI jobs.
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"
export TEST_PROVIDER='azurestack'
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
sed -i "s|ppe.azurestack.devcluster.openshift.com|ppe.upi.azurestack.devcluster.openshift.com|g" install-config.yaml

CLUSTER_NAME=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["metadata"]["name"])')
SSH_KEY=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["sshKey"])')
BASE_DOMAIN=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["baseDomain"])')
TENANT_ID=$(jq -r .tenantId ${SHARED_DIR}/osServicePrincipal.json)
AAD_CLIENT_SECRET=$(jq -r .clientSecret ${SHARED_DIR}/osServicePrincipal.json)
APP_ID=$(jq -r .clientId ${SHARED_DIR}/osServicePrincipal.json)

export CLUSTER_NAME
export SSH_KEY
export TENANT_ID
export BASE_DOMAIN
export AAD_CLIENT_SECRET
export APP_ID

echo $TENANT_ID >> ${SHARED_DIR}/TENANT_ID
echo $AAD_CLIENT_SECRET >> ${SHARED_DIR}/AAD_CLIENT_SECRET
echo $APP_ID >> ${SHARED_DIR}/APP_ID

# Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
source ${SHARED_DIR}/azurestack-login-script.sh

#Avoid x509 error thown out from installer when get azurestack wwt endpoint
if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
fi

export AZURE_AUTH_LOCATION="${SHARED_DIR}/osServicePrincipal.json"

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
rm -f openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml

cp ${SHARED_DIR}/manifest_* ./manifests
cat >> manifests/cco-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloud-credential-operator-config
  namespace: openshift-cloud-credential-operator
  annotations:
    release.openshift.io/create-only: "true"
data:
  disabled: "true"
EOF

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

az group create --name "$RESOURCE_GROUP" --location "$LEASED_RESOURCE"

KUBECONFIG="${dir}/auth/kubeconfig"
export KUBECONFIG

ACCOUNT_NAME=$(echo ${CLUSTER_NAME}sa | tr -cd '[:alnum:]')
echo "Creating storage account"
az storage account create -g "$RESOURCE_GROUP" --location "$LEASED_RESOURCE" --name "$ACCOUNT_NAME" --kind Storage --sku Standard_LRS
ACCOUNT_KEY=$(az storage account keys list -g "$RESOURCE_GROUP" --account-name "$ACCOUNT_NAME" --query "[0].value" -o tsv)

az storage container create --name files --account-name "${ACCOUNT_NAME}" --public-access blob --account-key "$ACCOUNT_KEY"
az storage blob upload --account-name "${ACCOUNT_NAME}" --account-key "$ACCOUNT_KEY" -c "files" -f "bootstrap.ign" -n "bootstrap.ign"

AZURESTACK_UPI_LOCATION="/var/lib/openshift-install/upi/azurestack"
az deployment group create -g "$RESOURCE_GROUP" \
  --template-file "${AZURESTACK_UPI_LOCATION}/01_vnet.json" \
  --parameters baseName="$INFRA_ID"

CLUSTER_OS_IMAGE=$(yq-go r "${SHARED_DIR}/install-config.yaml" 'platform.azure.ClusterOSImage')
az deployment group create -g "$RESOURCE_GROUP" \
  --template-file "${AZURESTACK_UPI_LOCATION}/02_storage.json" \
  --parameters vhdBlobURL="${CLUSTER_OS_IMAGE}" \
  --parameters baseName="$INFRA_ID"

az deployment group create -g "$RESOURCE_GROUP" \
  --template-file "${AZURESTACK_UPI_LOCATION}/03_infra.json" \
  --parameters baseName="$INFRA_ID"

az network dns zone create -g "$RESOURCE_GROUP" -n "${CLUSTER_NAME}.${BASE_DOMAIN}"
PUBLIC_IP=$(az network public-ip list -g "$RESOURCE_GROUP" --query "[?name=='${INFRA_ID}-master-pip'] | [0].ipAddress" -o tsv)
#on az version previouse to 2.45.0, property name is privateIpAddress
#on 2.45.0+, it changes to privateIPAddress
ip_keys='"privateIpAddress","privateIPAddress"'
PRIVATE_IP=$(az network lb frontend-ip show -g "$RESOURCE_GROUP" --lb-name "${INFRA_ID}-internal" -n internal-lb-ip | jq -r "with_entries(select(.key | IN($ip_keys))) | .[]")
az network dns record-set a add-record -g "$RESOURCE_GROUP" -z "${CLUSTER_NAME}.${BASE_DOMAIN}" -n api -a "$PUBLIC_IP" --ttl 60
az network dns record-set a add-record -g "$RESOURCE_GROUP" -z "${CLUSTER_NAME}.${BASE_DOMAIN}" -n api-int -a "$PRIVATE_IP" --ttl 60

BOOTSTRAP_URL=$(az storage blob url --account-name "${ACCOUNT_NAME}" --account-key "$ACCOUNT_KEY" -c "files" -n "bootstrap.ign" -o tsv)
if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
    CA="data:text/plain;charset=utf-8;base64,$(cat "${CLUSTER_PROFILE_DIR}/ca.pem" | base64 |tr -d '\n')"
    BOOTSTRAP_IGNITION=$(jq -rcnM --arg v "3.2.0" --arg url "$BOOTSTRAP_URL" --arg cert "$CA" '{ignition:{version:$v,security:{tls:{certificateAuthorities:[{source:$cert}]}},config:{replace:{source:$url}}}}' | base64 | tr -d '\n')
else
    BOOTSTRAP_IGNITION=$(jq -rcnM --arg v "3.2.0" --arg url "$BOOTSTRAP_URL" '{ignition:{version:$v,config:{replace:{source:$url}}}}' | base64 | tr -d '\n')
fi

az deployment group create --verbose -g "$RESOURCE_GROUP" \
  --template-file "${AZURESTACK_UPI_LOCATION}/04_bootstrap.json" \
  --parameters bootstrapIgnition="$BOOTSTRAP_IGNITION" \
  --parameters sshKeyData="$SSH_KEY" \
  --parameters baseName="$INFRA_ID" \
  --parameters diagnosticsStorageAccountName="${ACCOUNT_NAME}"

MASTER_IGNITION=$(cat master.ign | base64 | tr -d '\n')
az deployment group create -g "$RESOURCE_GROUP" \
  --template-file "${AZURESTACK_UPI_LOCATION}/05_masters.json" \
  --parameters masterIgnition="$MASTER_IGNITION" \
  --parameters sshKeyData="$SSH_KEY" \
  --parameters baseName="$INFRA_ID" \
  --parameters diagnosticsStorageAccountName="${ACCOUNT_NAME}"

BOOTSTRAP_PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-bootstrap-ssh-pip'] | [0].ipAddress" -o tsv)
MASTER0_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-0-nic --name pipConfig | jq -r "with_entries(select(.key | IN($ip_keys))) | .[]")
MASTER1_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-1-nic --name pipConfig | jq -r "with_entries(select(.key | IN($ip_keys))) | .[]")
MASTER2_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-2-nic --name pipConfig | jq -r "with_entries(select(.key | IN($ip_keys))) | .[]")

GATHER_BOOTSTRAP_ARGS=('--bootstrap' "${BOOTSTRAP_PUBLIC_IP}" '--master' "${MASTER0_IP}" '--master' "${MASTER1_IP}" '--master' "${MASTER2_IP}")

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
az storage blob delete --account-key "$ACCOUNT_KEY" --account-name "${ACCOUNT_NAME}" --container-name files --name bootstrap.ign
az network public-ip delete -g "$RESOURCE_GROUP" --name "${INFRA_ID}"-bootstrap-ssh-pip

WORKER_IGNITION=$(cat worker.ign | base64 | tr -d '\n')
az deployment group create -g "$RESOURCE_GROUP" \
  --template-file "${AZURESTACK_UPI_LOCATION}/06_workers.json" \
  --parameters workerIgnition="$WORKER_IGNITION" \
  --parameters sshKeyData="$SSH_KEY" \
  --parameters baseName="$INFRA_ID" \
  --parameters diagnosticsStorageAccountName="${ACCOUNT_NAME}"

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
