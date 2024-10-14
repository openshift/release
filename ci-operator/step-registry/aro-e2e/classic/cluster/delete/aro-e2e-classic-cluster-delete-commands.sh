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

  if [[ -z "${AZURE_CLUSTER_RESOURCE_GROUP}" ]]; then
      echo ">> AZURE_CLUSTER_RESOURCE_GROUP is not set"
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
}

function login {
  chmod +x ${SHARED_DIR}/azure-login.sh
  source ${SHARED_DIR}/azure-login.sh
}

function delete-cluster {
    echo "Delete ARO cluster with RP"

    RESOURCE_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_CLUSTER_RESOURCE_GROUP}/providers/Microsoft.RedHatOpenShift/openShiftClusters/${ARO_CLUSTER_NAME}"

    CSP_CLIENTID=$(curl -X GET \
            -k "${RP_ENDPOINT}${RESOURCE_ID}?api-version=2023-11-22" \
            --cert ./secrets/dev-client.pem \
            --silent | jq -r '.properties.servicePrincipalProfile.clientId')
    CSP_OBJECTID=$(az ad sp show --id ${CSP_CLIENTID} -o json | jq -r '.id')

    echo "Deleting cluster"
    curl -X DELETE "${CURL_ADDITIONAL_ARGS}" \
      -k "${RP_ENDPOINT}${RESOURCE_ID}?api-version=2023-11-22" \
      --cert ${CERT}

    echo "Waiting for cluster deletion to complete..."
    while true
    do
        STATE=$(curl -X GET "${CURL_ADDITIONAL_ARGS}" \
            -k "${RP_ENDPOINT}${RESOURCE_ID}?api-version=2023-11-22" \
            --cert ${CERT} \
            --silent | jq -r '.properties.provisioningState')

        case $STATE in
            "Deleting")
                echo "Cluster deletion in progress..."
                sleep 30
            ;;
            "null")
                echo "Cluster deletion completed successfully"
                break
            ;;
            *)
                echo "Cluster deletion in unexpected state: ${STATE}"
                exit 1
            ;;
        esac
    done

    echo "Deleting CSP role assignments"
    SCOPE="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_CLUSTER_RESOURCE_GROUP}"
    az role assignment delete --assignee ${CSP_OBJECTID} --scope ${SCOPE}

    echo "Deleting CSP"
    az ad app delete --id ${CSP_CLIENTID}
}

vars
verify
login
delete-cluster
