#!/bin/bash
set +e
echo "Deprovisioning cluster ..."
if [[ -f ${SHARED_DIR}/metadata.json ]]; then
    INFRA_ID="$(jq -r .infraID ${SHARED_DIR}/metadata.json)"
    AZURE_AUTH_CLIENT_ID=$(cat ${SHARED_DIR}/AZURE_AUTH_CLIENT_ID)
    AZURE_AUTH_CLIENT_SECRET=$(cat ${SHARED_DIR}/AZURE_AUTH_CLIENT_SECRET)
    AZURE_AUTH_TENANT_ID=$(cat ${SHARED_DIR}/AZURE_AUTH_TENANT_ID)
    AZURE_SUBSCRIPTION_ID=$(cat ${SHARED_DIR}/AZURE_SUBSCRIPTION_ID)
    az login --service-principal -u $AZURE_AUTH_CLIENT_ID -p "$AZURE_AUTH_CLIENT_SECRET" --tenant $AZURE_AUTH_TENANT_ID --output none
    az account set --subscription ${AZURE_SUBSCRIPTION_ID}

    
    if [ "$(az group list --query "[?name=='${INFRA_ID}-rg']" | jq length)" -ne 0 ] ; then
        az group delete --name ${INFRA_ID}-rg --yes
    fi
else
    echo "No metadata json file detected. Deprovision complete."
fi