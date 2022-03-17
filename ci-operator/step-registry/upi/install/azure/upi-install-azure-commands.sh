#!/bin/bash
set -euo pipefail

INSTALL_STAGE="initial"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save install status for must-gather to generate junit
trap 'echo "$? $INSTALL_STAGE" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.
export PATH=/tmp:${PATH}

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

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

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  echo "Vnet already created"
  VNET_FILE="${SHARED_DIR}/customer_vnet_subnets.yaml"
  vnet_name=$(/tmp/yq r ${VNET_FILE} 'platform.azure.virtualNetwork')
  vnet_basename=$(echo "${vnet_name}" | sed 's/-vnet$//') || exit 3
fi

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

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  echo "Using custom NSG in manifests"
  installer_infraID=$(cat .openshift_install_state.json | jq -j '."*installconfig.ClusterID".InfraID')
  sed -i "s/${installer_infraID}-nsg/${vnet_basename}-nsg/g" manifests/cloud-provider-config.yaml
fi

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
echo "INFRA_ID: ${INFRA_ID}"

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  echo "Getting RG"
  RESOURCE_GROUP=$(cat ${SHARED_DIR}/resouregroup)
  echo "Resource Group already created ${RESOURCE_GROUP}"

else
  RESOURCE_GROUP="${INFRA_ID}-rg"
  echo "Creating resource group ${RESOURCE_GROUP}"
  az group create --name $RESOURCE_GROUP --location $AZURE_REGION
fi

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

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  echo "VNET already created ${vnet_name}" 
  echo "Linking VNet to private DNS zone"
  az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${INFRA_ID}-network-link -v "${vnet_name}" -e false

else
  echo "Deploying 01_vnet"
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "01_vnet.json" \
    --parameters baseName="$INFRA_ID"

  echo "Linking VNet to private DNS zone"
  az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${INFRA_ID}-network-link -v "${INFRA_ID}-vnet" -e false
fi

echo "Deploying 02_storage"
VHD_BLOB_URL=$(az storage blob url --account-name $ACCOUNT_NAME --account-key $ACCOUNT_KEY -c vhd -n "rhcos.vhd" -o tsv)
az deployment group create -g $RESOURCE_GROUP \
  --template-file "02_storage.json" \
  --parameters vhdBlobURL="${VHD_BLOB_URL}" \
  --parameters baseName="$INFRA_ID"

echo "Deploying 03_infra"
if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  echo "Disconnected install. Use different infra file"
  cat > infra_file.json << EOF  
{
  "\$schema" : "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion" : "1.0.0.0",
  "parameters" : {
    "baseName" : {
      "type" : "string",
      "minLength" : 1,
      "metadata" : {
        "description" : "Base name to be used in resource names (usually the cluster's Infra ID)"
      }
    },
    "vnetBaseName": {
      "type": "string",
      "defaultValue": ""
    },
    "privateDNSZoneName" : {
      "type" : "string",
      "metadata" : {
        "description" : "Name of the private DNS zone"
      }
    }
  },
  "variables" : {
    "location" : "[resourceGroup().location]",
    "virtualNetworkName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-vnet')]",
    "virtualNetworkID" : "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]",
    "masterSubnetName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-master-subnet')]",
    "masterSubnetRef" : "[concat(variables('virtualNetworkID'), '/subnets/', variables('masterSubnetName'))]",
    "masterPublicIpAddressName" : "[concat(parameters('baseName'), '-master-pip')]",
    "masterPublicIpAddressID" : "[resourceId('Microsoft.Network/publicIPAddresses', variables('masterPublicIpAddressName'))]",
    "masterLoadBalancerName" : "[concat(parameters('baseName'), '-public-lb')]",
    "masterLoadBalancerID" : "[resourceId('Microsoft.Network/loadBalancers', variables('masterLoadBalancerName'))]",
    "internalLoadBalancerName" : "[concat(parameters('baseName'), '-internal-lb')]",
    "internalLoadBalancerID" : "[resourceId('Microsoft.Network/loadBalancers', variables('internalLoadBalancerName'))]",
    "skuName": "Standard"
  },
  "resources" : [
    {
      "apiVersion" : "2018-12-01",
      "type" : "Microsoft.Network/publicIPAddresses",
      "name" : "[variables('masterPublicIpAddressName')]",
      "location" : "[variables('location')]",
      "sku": {
        "name": "[variables('skuName')]"
      },
      "properties" : {
        "publicIPAllocationMethod" : "Static",
        "dnsSettings" : {
          "domainNameLabel" : "[variables('masterPublicIpAddressName')]"
        }
      }
    },
    {
      "apiVersion" : "2018-12-01",
      "type" : "Microsoft.Network/loadBalancers",
      "name" : "[variables('masterLoadBalancerName')]",
      "location" : "[variables('location')]",
      "sku": {
        "name": "[variables('skuName')]"
      },
      "dependsOn" : [
        "[concat('Microsoft.Network/publicIPAddresses/', variables('masterPublicIpAddressName'))]"
      ],
      "properties" : {
        "frontendIPConfigurations" : [
          {
            "name" : "public-lb-ip",
            "properties" : {
              "publicIPAddress" : {
                "id" : "[variables('masterPublicIpAddressID')]"
              }
            }
          }
        ],
        "backendAddressPools" : [
          {
            "name" : "public-lb-backend"
          }
        ],
        "loadBalancingRules" : [
          {
            "name" : "api-internal",
            "properties" : {
              "frontendIPConfiguration" : {
                "id" :"[concat(variables('masterLoadBalancerID'), '/frontendIPConfigurations/public-lb-ip')]"
              },
              "backendAddressPool" : {
                "id" : "[concat(variables('masterLoadBalancerID'), '/backendAddressPools/public-lb-backend')]"
              },
              "protocol" : "Tcp",
              "loadDistribution" : "Default",
              "idleTimeoutInMinutes" : 30,
              "frontendPort" : 6443,
              "backendPort" : 6443,
              "probe" : {
                "id" : "[concat(variables('masterLoadBalancerID'), '/probes/api-internal-probe')]"
              }
            }
          }
        ],
        "probes" : [
          {
            "name" : "api-internal-probe",
            "properties" : {
              "protocol" : "Https",
              "port" : 6443,
              "requestPath": "/readyz",
              "intervalInSeconds" : 10,
              "numberOfProbes" : 3
            }
          }
        ]
      }
    },
    {
      "apiVersion" : "2018-12-01",
      "type" : "Microsoft.Network/loadBalancers",
      "name" : "[variables('internalLoadBalancerName')]",
      "location" : "[variables('location')]",
      "sku": {
        "name": "[variables('skuName')]"
      },
      "properties" : {
        "frontendIPConfigurations" : [
          {
            "name" : "internal-lb-ip",
            "properties" : {
              "privateIPAllocationMethod" : "Dynamic",
              "subnet" : {
                "id" : "[variables('masterSubnetRef')]"
              },
              "privateIPAddressVersion" : "IPv4"
            }
          }
        ],
        "backendAddressPools" : [
          {
            "name" : "internal-lb-backend"
          }
        ],
        "loadBalancingRules" : [
          {
            "name" : "api-internal",
            "properties" : {
              "frontendIPConfiguration" : {
                "id" : "[concat(variables('internalLoadBalancerID'), '/frontendIPConfigurations/internal-lb-ip')]"
              },
              "frontendPort" : 6443,
              "backendPort" : 6443,
              "enableFloatingIP" : false,
              "idleTimeoutInMinutes" : 30,
              "protocol" : "Tcp",
              "enableTcpReset" : false,
              "loadDistribution" : "Default",
              "backendAddressPool" : {
                "id" : "[concat(variables('internalLoadBalancerID'), '/backendAddressPools/internal-lb-backend')]"
              },
              "probe" : {
                "id" : "[concat(variables('internalLoadBalancerID'), '/probes/api-internal-probe')]"
              }
            }
          },
          {
            "name" : "sint",
            "properties" : {
              "frontendIPConfiguration" : {
                "id" : "[concat(variables('internalLoadBalancerID'), '/frontendIPConfigurations/internal-lb-ip')]"
              },
              "frontendPort" : 22623,
              "backendPort" : 22623,
              "enableFloatingIP" : false,
              "idleTimeoutInMinutes" : 30,
              "protocol" : "Tcp",
              "enableTcpReset" : false,
              "loadDistribution" : "Default",
              "backendAddressPool" : {
                "id" : "[concat(variables('internalLoadBalancerID'), '/backendAddressPools/internal-lb-backend')]"
              },
              "probe" : {
                "id" : "[concat(variables('internalLoadBalancerID'), '/probes/sint-probe')]"
              }
            }
          }
        ],
        "probes" : [
          {
            "name" : "api-internal-probe",
            "properties" : {
              "protocol" : "Https",
              "port" : 6443,
              "requestPath": "/readyz",
              "intervalInSeconds" : 10,
              "numberOfProbes" : 3
            }
          },
          {
            "name" : "sint-probe",
            "properties" : {
              "protocol" : "Https",
              "port" : 22623,
              "requestPath": "/healthz",
              "intervalInSeconds" : 10,
              "numberOfProbes" : 3
            }
          }
        ]
      }
    },
    {
      "apiVersion": "2018-09-01",
      "type": "Microsoft.Network/privateDnsZones/A",
      "name": "[concat(parameters('privateDNSZoneName'), '/api')]",
      "location" : "[variables('location')]",
      "dependsOn" : [
        "[concat('Microsoft.Network/loadBalancers/', variables('internalLoadBalancerName'))]"
      ],
      "properties": {
        "ttl": 60,
        "aRecords": [
          {
            "ipv4Address": "[reference(variables('internalLoadBalancerName')).frontendIPConfigurations[0].properties.privateIPAddress]"
          }
        ]
      }
    },
    {
      "apiVersion": "2018-09-01",
      "type": "Microsoft.Network/privateDnsZones/A",
      "name": "[concat(parameters('privateDNSZoneName'), '/api-int')]",
      "location" : "[variables('location')]",
      "dependsOn" : [
        "[concat('Microsoft.Network/loadBalancers/', variables('internalLoadBalancerName'))]"
      ],
      "properties": {
        "ttl": 60,
        "aRecords": [
          {
            "ipv4Address": "[reference(variables('internalLoadBalancerName')).frontendIPConfigurations[0].properties.privateIPAddress]"
          }
        ]
      }
    }
  ]
}
EOF

  az deployment group create -g $RESOURCE_GROUP \
    --template-file "infra_file.json" \
    --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
    --parameters baseName="$INFRA_ID" \
    --parameters vnetBaseName="${vnet_basename}"  

else
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "03_infra.json" \
    --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
    --parameters baseName="$INFRA_ID"
fi

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

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  cat  > boot_file.json << EOF
{
  "\$schema" : "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion" : "1.0.0.0",
  "parameters" : {
    "baseName" : {
      "type" : "string",
      "minLength" : 1,
      "metadata" : {
        "description" : "Base name to be used in resource names (usually the cluster's Infra ID)"
      }
    },
    "vnetBaseName": {
      "type": "string",
      "defaultValue": ""
    },
    "bootstrapIgnition" : {
      "type" : "string",
      "minLength" : 1,
      "metadata" : {
        "description" : "Bootstrap ignition content for the bootstrap cluster"
      }
    },
    "sshKeyData" : {
      "type" : "securestring",
      "defaultValue" : "Unused",
      "metadata" : {
        "description" : "Unused"
      }
    },
    "bootstrapVMSize" : {
      "type" : "string",
      "defaultValue" : "Standard_D4s_v3",
      "metadata" : {
        "description" : "The size of the Bootstrap Virtual Machine"
      }
    }
  },
  "variables" : {
    "location" : "[resourceGroup().location]",
    "virtualNetworkName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-vnet')]",
    "virtualNetworkID" : "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]",
    "masterSubnetName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-master-subnet')]",
    "masterSubnetRef" : "[concat(variables('virtualNetworkID'), '/subnets/', variables('masterSubnetName'))]",
    "masterLoadBalancerName" : "[concat(parameters('baseName'), '-public-lb')]",
    "internalLoadBalancerName" : "[concat(parameters('baseName'), '-internal-lb')]",
    "sshKeyPath" : "/home/core/.ssh/authorized_keys",
    "identityName" : "[concat(parameters('baseName'), '-identity')]",
    "vmName" : "[concat(parameters('baseName'), '-bootstrap')]",
    "nicName" : "[concat(variables('vmName'), '-nic')]",
    "imageName" : "[concat(parameters('baseName'), '-image')]",
    "clusterNsgName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-nsg')]",
    "sshPublicIpAddressName" : "[concat(variables('vmName'), '-ssh-pip')]"
  },
  "resources" : [
    {
      "apiVersion" : "2018-12-01",
      "type" : "Microsoft.Network/publicIPAddresses",
      "name" : "[variables('sshPublicIpAddressName')]",
      "location" : "[variables('location')]",
      "sku": {
        "name": "Standard"
      },
      "properties" : {
        "publicIPAllocationMethod" : "Static",
        "dnsSettings" : {
          "domainNameLabel" : "[variables('sshPublicIpAddressName')]"
        }
      }
    },
    {
      "apiVersion" : "2018-06-01",
      "type" : "Microsoft.Network/networkInterfaces",
      "name" : "[variables('nicName')]",
      "location" : "[variables('location')]",
      "dependsOn" : [
        "[resourceId('Microsoft.Network/publicIPAddresses', variables('sshPublicIpAddressName'))]"
      ],
      "properties" : {
        "ipConfigurations" : [
          {
            "name" : "pipConfig",
            "properties" : {
              "privateIPAllocationMethod" : "Dynamic",
              "publicIPAddress": {
                "id": "[resourceId('Microsoft.Network/publicIPAddresses', variables('sshPublicIpAddressName'))]"
              },
              "subnet" : {
                "id" : "[variables('masterSubnetRef')]"
              },
              "loadBalancerBackendAddressPools" : [
                {
                  "id" : "[concat('/subscriptions/', subscription().subscriptionId, '/resourceGroups/', resourceGroup().name, '/providers/Microsoft.Network/loadBalancers/', variables('masterLoadBalancerName'), '/backendAddressPools/public-lb-backend')]"
                },
                {
                  "id" : "[concat('/subscriptions/', subscription().subscriptionId, '/resourceGroups/', resourceGroup().name, '/providers/Microsoft.Network/loadBalancers/', variables('internalLoadBalancerName'), '/backendAddressPools/internal-lb-backend')]"
                }
              ]
            }
          }
        ]
      }
    },
    {
      "apiVersion" : "2018-06-01",
      "type" : "Microsoft.Compute/virtualMachines",
      "name" : "[variables('vmName')]",
      "location" : "[variables('location')]",
      "identity" : {
        "type" : "userAssigned",
        "userAssignedIdentities" : {
          "[resourceID('Microsoft.ManagedIdentity/userAssignedIdentities/', variables('identityName'))]" : {}
        }
      },
      "dependsOn" : [
        "[concat('Microsoft.Network/networkInterfaces/', variables('nicName'))]"
      ],
      "properties" : {
        "hardwareProfile" : {
          "vmSize" : "[parameters('bootstrapVMSize')]"
        },
        "osProfile" : {
          "computerName" : "[variables('vmName')]",
          "adminUsername" : "core",
          "adminPassword" : "NotActuallyApplied!",
          "customData" : "[parameters('bootstrapIgnition')]",
          "linuxConfiguration" : {
            "disablePasswordAuthentication" : false
          }
        },
        "storageProfile" : {
          "imageReference": {
            "id": "[resourceId('Microsoft.Compute/images', variables('imageName'))]"
          },
          "osDisk" : {
            "name": "[concat(variables('vmName'),'_OSDisk')]",
            "osType" : "Linux",
            "createOption" : "FromImage",
            "managedDisk": {
              "storageAccountType": "Premium_LRS"
            },
            "diskSizeGB" : 100
          }
        },
        "networkProfile" : {
          "networkInterfaces" : [
            {
              "id" : "[resourceId('Microsoft.Network/networkInterfaces', variables('nicName'))]"
            }
          ]
        }
      }
    },
    {
      "apiVersion" : "2018-06-01",
      "type": "Microsoft.Network/networkSecurityGroups/securityRules",
      "name" : "[concat(variables('clusterNsgName'), '/bootstrap_ssh_in')]",
      "location" : "[variables('location')]",
      "dependsOn" : [
        "[resourceId('Microsoft.Compute/virtualMachines', variables('vmName'))]"
      ],
      "properties": {
        "protocol" : "Tcp",
        "sourcePortRange" : "*",
        "destinationPortRange" : "22",
        "sourceAddressPrefix" : "*",
        "destinationAddressPrefix" : "*",
        "access" : "Allow",
        "priority" : 100,
        "direction" : "Inbound"
      }
    }
  ]
}
EOF
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "boot_file.json" \
    --parameters bootstrapIgnition="$BOOTSTRAP_IGNITION" \
    --parameters sshKeyData="$SSH_PUB_KEY" \
    --parameters baseName="$INFRA_ID" \
    --parameters vnetBaseName="${vnet_basename}"

else
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "04_bootstrap.json" \
    --parameters bootstrapIgnition="$BOOTSTRAP_IGNITION" \
    --parameters sshKeyData="$SSH_PUB_KEY" \
    --parameters baseName="$INFRA_ID"
fi

BOOTSTRAP_PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-bootstrap-ssh-pip'] | [0].ipAddress" -o tsv)
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --bootstrap ${BOOTSTRAP_PUBLIC_IP}"

echo "Deploying 05_masters"
MASTER_IGNITION=$(cat ${ARTIFACT_DIR}/installer/master.ign | base64 -w0)

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  cat > master_file.json << EOF
{
  "\$schema" : "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion" : "1.0.0.0",
  "parameters" : {
    "baseName" : {
      "type" : "string",
      "minLength" : 1,
      "metadata" : {
        "description" : "Base name to be used in resource names (usually the cluster's Infra ID)"
      }
    },
    "vnetBaseName": {
      "type": "string",
      "defaultValue": ""
    },
    "masterIgnition" : {
      "type" : "string",
      "metadata" : {
        "description" : "Ignition content for the master nodes"
      }
    },
    "numberOfMasters" : {
      "type" : "int",
      "defaultValue" : 3,
      "minValue" : 2,
      "maxValue" : 30,
      "metadata" : {
        "description" : "Number of OpenShift masters to deploy"
      }
    },
    "sshKeyData" : {
      "type" : "securestring",
      "defaultValue" : "Unused",
      "metadata" : {
        "description" : "Unused"
      }
    },
    "privateDNSZoneName" : {
      "type" : "string",
      "defaultValue" : "",
      "metadata" : {
        "description" : "unused"
      }
    },
    "masterVMSize" : {
      "type" : "string",
      "defaultValue" : "Standard_D8s_v3",      
      "metadata" : {
        "description" : "The size of the Master Virtual Machines"
      }
    },
    "diskSizeGB" : {
      "type" : "int",
      "defaultValue" : 1024,
      "metadata" : {
        "description" : "Size of the Master VM OS disk, in GB"
      }
    }
  },
  "variables" : {
    "location" : "[resourceGroup().location]",
    "virtualNetworkName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-vnet')]",
    "virtualNetworkID" : "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]",
    "masterSubnetName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-master-subnet')]",
    "masterSubnetRef" : "[concat(variables('virtualNetworkID'), '/subnets/', variables('masterSubnetName'))]",
    "masterLoadBalancerName" : "[concat(parameters('baseName'), '-public-lb')]",
    "internalLoadBalancerName" : "[concat(parameters('baseName'), '-internal-lb')]",
    "sshKeyPath" : "/home/core/.ssh/authorized_keys",
    "identityName" : "[concat(parameters('baseName'), '-identity')]",
    "imageName" : "[concat(parameters('baseName'), '-image')]",
    "copy" : [
      {
        "name" : "vmNames",
        "count" :  "[parameters('numberOfMasters')]",
        "input" : "[concat(parameters('baseName'), '-master-', copyIndex('vmNames'))]"
      }
    ]
  },
  "resources" : [
    {
      "apiVersion" : "2018-06-01",
      "type" : "Microsoft.Network/networkInterfaces",
      "copy" : {
        "name" : "nicCopy",
        "count" : "[length(variables('vmNames'))]"
      },
      "name" : "[concat(variables('vmNames')[copyIndex()], '-nic')]",
      "location" : "[variables('location')]",
      "properties" : {
        "ipConfigurations" : [
          {
            "name" : "pipConfig",
            "properties" : {
              "privateIPAllocationMethod" : "Dynamic",
              "subnet" : {
                "id" : "[variables('masterSubnetRef')]"
              },
              "loadBalancerBackendAddressPools" : [
                {
                  "id" : "[concat('/subscriptions/', subscription().subscriptionId, '/resourceGroups/', resourceGroup().name, '/providers/Microsoft.Network/loadBalancers/', variables('masterLoadBalancerName'), '/backendAddressPools/public-lb-backend')]"
                },
                {
                  "id" : "[concat('/subscriptions/', subscription().subscriptionId, '/resourceGroups/', resourceGroup().name, '/providers/Microsoft.Network/loadBalancers/', variables('internalLoadBalancerName'), '/backendAddressPools/internal-lb-backend')]"
                }
              ]
            }
          }
        ]
      }
    },
    {
      "apiVersion" : "2018-06-01",
      "type" : "Microsoft.Compute/virtualMachines",
      "copy" : {
        "name" : "vmCopy",
        "count" : "[length(variables('vmNames'))]"
      },
      "name" : "[variables('vmNames')[copyIndex()]]",
      "location" : "[variables('location')]",
      "identity" : {
        "type" : "userAssigned",
        "userAssignedIdentities" : {
          "[resourceID('Microsoft.ManagedIdentity/userAssignedIdentities/', variables('identityName'))]" : {}
        }
      },
      "dependsOn" : [
        "[concat('Microsoft.Network/networkInterfaces/', concat(variables('vmNames')[copyIndex()], '-nic'))]"       
      ],
      "properties" : {
        "hardwareProfile" : {
          "vmSize" : "[parameters('masterVMSize')]"
        },
        "osProfile" : {
          "computerName" : "[variables('vmNames')[copyIndex()]]",
          "adminUsername" : "core",
          "adminPassword" : "NotActuallyApplied!",
          "customData" : "[parameters('masterIgnition')]",
          "linuxConfiguration" : {
            "disablePasswordAuthentication" : false            
          }
        },
        "storageProfile" : {
          "imageReference": {
            "id": "[resourceId('Microsoft.Compute/images', variables('imageName'))]"
          },
          "osDisk" : {
            "name": "[concat(variables('vmNames')[copyIndex()], '_OSDisk')]",
            "osType" : "Linux",
            "createOption" : "FromImage",
            "caching": "ReadOnly",
            "writeAcceleratorEnabled": false,
            "managedDisk": {
              "storageAccountType": "Premium_LRS"
            },
            "diskSizeGB" : "[parameters('diskSizeGB')]"
          }
        },
        "networkProfile" : {
          "networkInterfaces" : [
            {
              "id" : "[resourceId('Microsoft.Network/networkInterfaces', concat(variables('vmNames')[copyIndex()], '-nic'))]",
              "properties": {
                "primary": false
              }
            }
          ]
        }
      }
    }
  ]
}
EOF

  az deployment group create -g $RESOURCE_GROUP \
    --template-file "master_file.json" \
    --parameters masterIgnition="$MASTER_IGNITION" \
    --parameters sshKeyData="$SSH_PUB_KEY" \
    --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
    --parameters baseName="$INFRA_ID" \
    --parameters vnetBaseName="${vnet_basename}"

else
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "05_masters.json" \
    --parameters masterIgnition="$MASTER_IGNITION" \
    --parameters sshKeyData="$SSH_PUB_KEY" \
    --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
    --parameters baseName="$INFRA_ID"
fi

MASTER0_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-0-nic --name pipConfig --query "privateIpAddress" -o tsv)
MASTER1_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-1-nic --name pipConfig --query "privateIpAddress" -o tsv)
MASTER2_IP=$(az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${INFRA_ID}-master-2-nic --name pipConfig --query "privateIpAddress" -o tsv)
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --master ${MASTER0_IP} --master ${MASTER1_IP} --master ${MASTER2_IP}"

echo "Deploying 06_workers"
WORKER_IGNITION=$(cat ${ARTIFACT_DIR}/installer/worker.ign | base64 -w0)
export WORKER_IGNITION

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  cat > worker_file.json << EOF
{
  "\$schema" : "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
  "contentVersion" : "1.0.0.0",
  "parameters" : {
    "baseName" : {
      "type" : "string",
      "minLength" : 1,
      "metadata" : {
        "description" : "Base name to be used in resource names (usually the cluster's Infra ID)"
      }
    },
    "vnetBaseName": {
      "type": "string",
      "defaultValue": ""
    },
    "workerIgnition" : {
      "type" : "string",
      "metadata" : {
        "description" : "Ignition content for the worker nodes"
      }
    },
    "numberOfNodes" : {
      "type" : "int",
      "defaultValue" : 3,
      "minValue" : 2,
      "maxValue" : 30,
      "metadata" : {
        "description" : "Number of OpenShift compute nodes to deploy"
      }
    },
    "sshKeyData" : {
      "type" : "securestring",
      "defaultValue" : "Unused",
      "metadata" : {
        "description" : "Unused"
      }
    },
    "nodeVMSize" : {
      "type" : "string",
      "defaultValue" : "Standard_D4s_v3",
      "metadata" : {
        "description" : "The size of the each Node Virtual Machine"
      }
    }
  },
  "variables" : {
    "location" : "[resourceGroup().location]",
    "virtualNetworkName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-vnet')]",
    "virtualNetworkID" : "[resourceId('Microsoft.Network/virtualNetworks', variables('virtualNetworkName'))]",
    "nodeSubnetName" : "[concat(if(not(empty(parameters('vnetBaseName'))), parameters('vnetBaseName'), parameters('baseName')), '-worker-subnet')]",
    "nodeSubnetRef" : "[concat(variables('virtualNetworkID'), '/subnets/', variables('nodeSubnetName'))]",
    "infraLoadBalancerName" : "[parameters('baseName')]",
    "sshKeyPath" : "/home/capi/.ssh/authorized_keys",
    "identityName" : "[concat(parameters('baseName'), '-identity')]",
    "imageName" : "[concat(parameters('baseName'), '-image')]",
    "copy" : [
      {
        "name" : "vmNames",
        "count" :  "[parameters('numberOfNodes')]",
        "input" : "[concat(parameters('baseName'), '-worker-', variables('location'), '-', copyIndex('vmNames', 1))]"
      }
    ]
  },
  "resources" : [
    {
      "apiVersion" : "2019-05-01",
      "name" : "[concat('node', copyIndex())]",
      "type" : "Microsoft.Resources/deployments",
      "copy" : {
        "name" : "nodeCopy",
        "count" : "[length(variables('vmNames'))]"
      },
      "properties" : {
        "mode" : "Incremental",
        "template" : {
          "\$schema" : "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
          "contentVersion" : "1.0.0.0",
          "resources" : [
            {
              "apiVersion" : "2018-06-01",
              "type" : "Microsoft.Network/networkInterfaces",
              "name" : "[concat(variables('vmNames')[copyIndex()], '-nic')]",
              "location" : "[variables('location')]",
              "properties" : {
                "ipConfigurations" : [
                  {
                    "name" : "pipConfig",
                    "properties" : {
                      "privateIPAllocationMethod" : "Dynamic",
                      "subnet" : {
                        "id" : "[variables('nodeSubnetRef')]"
                      }
                    }
                  }
                ]
              }
            },
            {
              "apiVersion" : "2018-06-01",
              "type" : "Microsoft.Compute/virtualMachines",
              "name" : "[variables('vmNames')[copyIndex()]]",
              "location" : "[variables('location')]",
              "tags" : {
                "kubernetes.io-cluster-ffranzupi": "owned"
              },
              "identity" : {
                "type" : "userAssigned",
                "userAssignedIdentities" : {
                  "[resourceID('Microsoft.ManagedIdentity/userAssignedIdentities/', variables('identityName'))]" : {}
                }
              },
              "dependsOn" : [
                "[concat('Microsoft.Network/networkInterfaces/', concat(variables('vmNames')[copyIndex()], '-nic'))]"
              ],
              "properties" : {
                "hardwareProfile" : {
                  "vmSize" : "[parameters('nodeVMSize')]"
                },
                "osProfile" : {
                  "computerName" : "[variables('vmNames')[copyIndex()]]",
                  "adminUsername" : "capi",
                  "adminPassword" : "NotActuallyApplied!",
                  "customData" : "[parameters('workerIgnition')]",
                  "linuxConfiguration" : {
                    "disablePasswordAuthentication" : false
                  }
                },
                "storageProfile" : {
                  "imageReference": {
                    "id": "[resourceId('Microsoft.Compute/images', variables('imageName'))]"
                  },
                  "osDisk" : {
                    "name": "[concat(variables('vmNames')[copyIndex()],'_OSDisk')]",
                    "osType" : "Linux",
                    "createOption" : "FromImage",
                    "managedDisk": {
                      "storageAccountType": "Premium_LRS"
                    },
                    "diskSizeGB": 128
                  }
                },
                "networkProfile" : {
                  "networkInterfaces" : [
                    {
                      "id" : "[resourceId('Microsoft.Network/networkInterfaces', concat(variables('vmNames')[copyIndex()], '-nic'))]",
                      "properties": {
                        "primary": true
                      }
                    }
                  ]
                }
              }
            }
          ]
        }
      }
    }
  ]
}
EOF

  az deployment group create -g $RESOURCE_GROUP \
    --template-file "worker_file.json" \
    --parameters workerIgnition="$WORKER_IGNITION" \
    --parameters sshKeyData="$SSH_PUB_KEY" \
    --parameters baseName="$INFRA_ID" \
    --parameters vnetBaseName="${vnet_basename}"

else
  az deployment group create -g $RESOURCE_GROUP \
    --template-file "06_workers.json" \
    --parameters workerIgnition="$WORKER_IGNITION" \
    --parameters sshKeyData="$SSH_PUB_KEY" \
    --parameters baseName="$INFRA_ID"
fi

popd

# Check if proxy is set
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  echo "Private cluster setting proxy"
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Waiting for bootstrap to complete"
openshift-install --dir=${ARTIFACT_DIR}/installer wait-for bootstrap-complete &
wait "$!" || gather_bootstrap_and_fail

INSTALL_STAGE="bootstrap_successful"
echo "Bootstrap complete, destroying bootstrap resources"

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  az network nsg rule delete -g $RESOURCE_GROUP --nsg-name ${vnet_basename}-nsg --name bootstrap_ssh_in

else
  az network nsg rule delete -g $RESOURCE_GROUP --nsg-name ${INFRA_ID}-nsg --name bootstrap_ssh_in
fi

az vm stop -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap
az vm deallocate -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap
az vm delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap --yes
az disk delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap_OSDisk --no-wait --yes
az network nic delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap-nic --no-wait
az storage blob delete --account-key $ACCOUNT_KEY --account-name $ACCOUNT_NAME --container-name files --name bootstrap.ign
az network public-ip delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap-ssh-pip

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

echo "Adding ingress DNS records"

export KUBECONFIG=${ARTIFACT_DIR}/installer/auth/kubeconfig
# Check if proxy is set
# if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # echo "Private cluster setting proxy"
  # shellcheck disable=SC1090
  # source "${SHARED_DIR}/proxy-conf.sh"
# fi

set +e
public_ip_router="<pending>"
while [[ ($public_ip_router == "<pending>") || ($public_ip_router == "") ]]
do
  sleep 10
  public_ip_router=$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')
  echo $public_ip_router
  nodes=$(oc get node --all-namespaces)
  echo $nodes
done
set -e

public=$(oc -n openshift-ingress get service router-default)
echo "service headers ${public}"

az network dns record-set a add-record -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} -n *.apps.${CLUSTER_NAME} -a $public_ip_router --ttl 300

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $public_ip_router

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
