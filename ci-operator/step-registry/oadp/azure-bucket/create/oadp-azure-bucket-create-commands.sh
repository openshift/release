#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set variables needed to login to AZURE
export SERVICE_PRINCIPAL="true"
export SERVICE_PRINCIPAL_FILE="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"

export CLIENT_ID
CLIENT_ID=$(jq -r .clientId ${SERVICE_PRINCIPAL_FILE})

export CLIENT_SECRET
CLIENT_SECRET=$(jq -r .clientSecret ${SERVICE_PRINCIPAL_FILE})

export TENANT_ID
TENANT_ID=$(jq -r .tenantId ${SERVICE_PRINCIPAL_FILE})

# Set BUCKET variable to a unique value
export BUCKET="${NAMESPACE}-${BUCKET_NAME}"

# Create S3 Bucket to Use for Testing
/bin/bash /home/jenkins/oadp-qe-automation/backup-locations/azure/deploy.sh $BUCKET
cp credentials $SHARED_DIR