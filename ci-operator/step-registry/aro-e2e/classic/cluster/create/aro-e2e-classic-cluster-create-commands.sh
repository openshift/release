#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CERT="${SHARED_DIR}/dev-client.pem"

function vars {
  source ${SHARED_DIR}/vars.sh
}

function verify {
  if [[ -z "${AZURE_SUBSCRIPTION_ID}" ]]; then
      echo ">> AZURE_SUBSCRIPTION_ID is not set"
      exit 1
  fi

  if [[ -z "${AZURE_LOCATION}" ]]; then
      echo ">> AZURE_LOCATION is not set"
      exit 1
  fi

  if [[ -z "${AZURE_CLUSTER_RESOURCE_GROUP}" ]]; then
      echo ">> AZURE_CLUSTER_RESOURCE_GROUP is not set"
      exit 1
  fi

  if [[ -z "${ARO_CLUSTER_SERVICE_PRINCIPAL_NAME}" ]]; then
      echo ">> ARO_CLUSTER_SERVICE_PRINCIPAL_NAME is not set"
      exit 1
  fi

  if [[ -z "${RP_ENDPOINT}" ]]; then
      echo ">> RP_ENDPOINT is not set"
      exit 1
  fi

  if [[ -z "${ARO_CLUSTER_NAME}" ]]; then
      echo ">> ARO_CLUSTER_NAME is not set"
      exit 1
  fi

  if [[ -z "${ARO_VERSION}" ]]; then
      echo ">> ARO_VERSION is not set"
      exit 1
  fi

  if [[ -z "${RELEASE_IMAGE_LATEST}" ]]; then
      echo ">> RELEASE_IMAGE_LATEST is not set"
      exit 1
  fi

  if [[ -z "${ARO_VERSION_INSTALLER_PULLSPEC}" ]]; then
      echo ">> ARO_VERSION_INSTALLER_PULLSPEC is not set"
      exit 1
  fi
}

function login {
  chmod +x ${SHARED_DIR}/azure-login.sh
  source ${SHARED_DIR}/azure-login.sh
}

function create-cluster {
  echo "Create ARO cluster with RP"
  echo "Creating cluster service principal with name ${ARO_CLUSTER_SERVICE_PRINCIPAL_NAME}"

  # We currently can't create a new service principal, use the CI sp...
  # TODO figure out how to allow sp creation, and revert this, and delete sp_password and sp_objectid from vault
  #az ad sp create-for-rbac --name "${ARO_CLUSTER_SERVICE_PRINCIPAL_NAME}" > cluster-service-principal.json
  #CSP_CLIENTID=$(jq -r '.appId' cluster-service-principal.json)
  #CSP_CLIENTSECRET=$(jq -r '.password' cluster-service-principal.json)
  #CSP_OBJECTID=$(az ad sp show --id ${CSP_CLIENTID} -o json | jq -r '.id')
  #rm cluster-service-principal.json

  CSP_CLIENTID="$(<"${CLUSTER_PROFILE_DIR}/sp_id")"
  CSP_CLIENTSECRET="$(<"${CLUSTER_PROFILE_DIR}/sp_password")"
  CSP_OBJECTID="$(<"${CLUSTER_PROFILE_DIR}/sp_objectid")"

  echo "Creating role assignments for cluster service principal"
  SCOPE="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_CLUSTER_RESOURCE_GROUP}"
  az role assignment create \
      --role 'User Access Administrator' \
      --assignee-object-id ${CSP_OBJECTID} \
      --scope ${SCOPE} \
      --assignee-principal-type 'ServicePrincipal'

  az role assignment create \
      --role 'Contributor' \
      --assignee-object-id ${CSP_OBJECTID} \
      --scope ${SCOPE} \
      --assignee-principal-type 'ServicePrincipal'

  echo "Registering cluster version ${ARO_VERSION} to the RP"
  curl -X PUT -x "${CURL_PROXY}" \
      -k "${RP_ENDPOINT}/admin/versions" \
      --cert ${CERT} \
      --header "Content-Type: application/json" \
      --data-binary @- <<EOF
{
    "properties": {
        "version": "${ARO_VERSION}",
        "enabled": true,
        "openShiftPullspec": "${RELEASE_IMAGE_LATEST}",
        "installerPullspec": "${ARO_VERSION_INSTALLER_PULLSPEC}"
    }
}
EOF

  echo "Creating cluster"
  RESOURCE_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_CLUSTER_RESOURCE_GROUP}/providers/Microsoft.RedHatOpenShift/openShiftClusters/${ARO_CLUSTER_NAME}"
  RANDOM_ID=$(tr -dc a-z </dev/urandom | head -c 1; tr -dc a-z0-9 </dev/urandom | head -c 7)
  MANAGED_RESOURCE_GROUP_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/aro-${RANDOM_ID}"
  VNET_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_CLUSTER_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/cluster-vnet"
  MASTER_SUBNET_ID="${VNET_ID}/subnets/master"
  WORKER_SUBNET_ID="${VNET_ID}/subnets/worker"

  curl -X PUT -x "${CURL_PROXY}" \
      -k "${RP_ENDPOINT}${RESOURCE_ID}?api-version=2023-11-22" \
      --cert ${CERT} \
      --header "Content-Type: application/json" \
      --data-binary @- <<EOF
{
    "location": "${AZURE_LOCATION}",
    "properties": {
        "clusterProfile": {
            "domain": "${RANDOM_ID}", "resourceGroupId": "${MANAGED_RESOURCE_GROUP_ID}",
            "version": "${ARO_VERSION}", "fipsValidatedModules": "Disabled"
        },
        "servicePrincipalProfile": {"clientId": "${CSP_CLIENTID}", "clientSecret": "${CSP_CLIENTSECRET}"},
        "networkProfile": {"podCidr": "10.128.0.0/14", "serviceCidr": "172.30.0.0/16"},
        "masterProfile": {
            "vmSize": "Standard_D8s_v3", "subnetId": "${MASTER_SUBNET_ID}", "encryptionAtHost": "Disabled"
        },
        "workerProfiles": [{
            "name": "worker", "count": 3, "diskSizeGb": 128,
            "vmSize": "Standard_D2s_v3", "subnetId": "${WORKER_SUBNET_ID}", "encryptionAtHost": "Disabled"
        }],
        "apiserverProfile": {"visibility": "Public"},
        "ingressProfiles": [{"name": "default", "visibility": "Public"}]
    }
}
EOF

  echo "Waiting for cluster creation to complete..."
  while true
  do
      STATE=$(curl -X GET -x "${CURL_PROXY}" \
          -k "${RP_ENDPOINT}${RESOURCE_ID}?api-version=2023-11-22" \
          --cert ${CERT} \
          --silent | jq -r '.properties.provisioningState')

      case $STATE in
          "Creating")
              echo "Cluster creation in progress..."
              sleep 30
          ;;
          "Succeeded")
              echo "Cluster creation completed successfully"
              break
          ;;
          "Failed")
              echo "Cluster creation failed"
              echo "Getting install logs"

              curl -X GET -x "${CURL_PROXY}" \
                  -k "${RP_ENDPOINT}/admin${RESOURCE_ID}/clusterdeployment?api-version=2023-11-22" \
                  --cert ${CERT} \
                  --silent \
              | jq -r '.status.conditions | map(select(.type == "ProvisionFailed")) | .[0].message' \
              | sed -e 's/\\n/\n/g'

              exit 1
          ;;
          *)
              echo "Cluster creation in unexpected state: ${STATE}"
              exit 1
          ;;
      esac
  done
}

function get-kubeconfig {
    echo "Getting cluster kubeconfig"
    RESOURCE_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_CLUSTER_RESOURCE_GROUP}/providers/Microsoft.RedHatOpenShift/openShiftClusters/${ARO_CLUSTER_NAME}"
    curl -X POST -x "${CURL_PROXY}" \
        -k "${RP_ENDPOINT}${RESOURCE_ID}/listadmincredentials?api-version=2023-11-22" \
        --cert ${CERT} \
        --header "Content-Type: application/json" \
        --silent | jq -r .kubeconfig | base64 -d > ${SHARED_DIR}/kubeconfig
}

# for saving files...
cd /tmp

vars
verify
login
create-cluster
get-kubeconfig
