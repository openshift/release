#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# IBM Cloud CLI login
function ibmcloud_login {
  export IBMCLOUD_CLI=ibmcloud
  export IBMCLOUD_HOME=/output
  region="${LEASED_RESOURCE}"
  export region
  "${IBMCLOUD_CLI}" config --check-version=false
  echo "Try to login..."
  "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

ibmcloud_login
resource_group=$(cat "${SHARED_DIR}/ibmcloud_resource_group")
"${IBMCLOUD_CLI}" target -g ${resource_group}



remove_resources_by_cli="${SHARED_DIR}/ibmcloud_remove_resources_by_cli.sh"
if [ -f "${remove_resources_by_cli}" ]; then
    sh -x "${remove_resources_by_cli}"
fi
