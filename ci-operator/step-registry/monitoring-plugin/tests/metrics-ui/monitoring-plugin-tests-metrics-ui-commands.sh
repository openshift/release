#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# List of variables to check.
vars=(
  CYPRESS_SKIP_COO_INSTALL
  CYPRESS_COO_UI_INSTALL
  CYPRESS_KONFLUX_COO_BUNDLE_IMAGE
  CYPRESS_CUSTOM_COO_BUNDLE_IMAGE
  CYPRESS_MCP_CONSOLE_IMAGE
  CYPRESS_MP_IMAGE
  CYPRESS_FBC_STAGE_COO_IMAGE
  CYPRESS_TIMEZONE
  CYPRESS_SESSION
  CYPRESS_DEBUG
  CYPRESS_SKIP_KBV_INSTALL
  CYPRESS_KBV_UI_INSTALL
  CYPRESS_KONFLUX_KBV_BUNDLE_IMAGE
  CYPRESS_CUSTOM_KBV_BUNDLE_IMAGE
  CYPRESS_FBC_STAGE_KBV_IMAGE
)

# Loop through each variable.
for var in "${vars[@]}"; do
  if [[ -z "${!var}" ]]; then
    unset "$var"
    echo "Unset variable: $var"
  else
    echo "$var is set to '${!var}'"
  fi
done

# Read kubeadmin password from file
if [[ -z "${KUBEADMIN_PASSWORD_FILE:-}" ]]; then
  echo "Error: KUBEADMIN_PASSWORD_FILE variable is not set"
  exit 0
fi

if [[ ! -f "${KUBEADMIN_PASSWORD_FILE}" ]]; then
  echo "Error: Kubeadmin password file ${KUBEADMIN_PASSWORD_FILE} does not exist"
  exit 0
fi

kubeadmin_password=$(cat "${KUBEADMIN_PASSWORD_FILE}")
echo "Successfully read kubeadmin password from ${KUBEADMIN_PASSWORD_FILE}"

# Set proxy vars.
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

## skip all tests when console is not installed.
if ! (oc get clusteroperator console --kubeconfig=${KUBECONFIG}) ; then
  echo "console is not installed, skipping all console tests."
  exit 0
fi

# Function to copy artifacts to the artifact directory after test run.
function copyArtifacts {
  if [ -d "/tmp/monitoring-plugin/web/cypress/screenshots/" ]; then
    cp -r /tmp/monitoring-plugin/web/cypress/screenshots/ "${ARTIFACT_DIR}/screenshots"
    echo "Screenshots copied successfully."
  else
    echo "Directory screenshots does not exist. Nothing to copy."
  fi
  if [ -d "/tmp/monitoring-plugin/web/cypress/videos/" ]; then
    cp -r /tmp/monitoring-plugin/web/cypress/videos/ "${ARTIFACT_DIR}/videos"
    echo "Videos copied successfully."
  else
    echo "Directory videos does not exist. Nothing to copy."
  fi
}

# when claiming a cluster from cluster pool, it stucks
## Add IDP for testing
# prepare users
# users=""
# htpass_file=/tmp/users.htpasswd

# for i in $(seq 1 5); do
#     username="uiauto-test-${i}"
#     password=$(tr </dev/urandom -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
#     users+="${username}:${password},"
#     if [ -f "${htpass_file}" ]; then
#         htpasswd -B -b ${htpass_file} "${username}" "${password}"
#     else
#         htpasswd -c -B -b ${htpass_file} "${username}" "${password}"
#     fi
# done

# # remove trailing ',' for case parsing
# users=${users%?}

# # current generation
# gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')

# # add users to cluster
# oc create secret generic uiauto-htpass-secret --from-file=htpasswd=${htpass_file} -n openshift-config
# oc patch oauth cluster --type='json' -p='[{"op": "add", "path": "/spec/identityProviders", "value": [{"type": "HTPasswd", "name": "uiauto-htpasswd-idp", "mappingMethod": "claim", "htpasswd":{"fileData":{"name": "uiauto-htpass-secret"}}}]}]'

# ## wait for oauth-openshift to rollout
# wait_auth=true
# expected_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.spec.replicas}')
# while $wait_auth; do
#     available_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.availableReplicas}')
#     new_gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
#     if [[ $expected_replicas == "$available_replicas" && $((new_gen)) -gt $((gen)) ]]; then
#         wait_auth=false
#     else
#         sleep 10
#     fi
# done
# echo "authentication operator finished updating"

# Copy the artifacts to the aritfact directory at the end of the test run.
trap copyArtifacts EXIT

# Set Kubeconfig var for Cypress.
cp -L $KUBECONFIG /tmp/kubeconfig && export CYPRESS_KUBECONFIG_PATH=/tmp/kubeconfig

# Set Cypress base URL var.
console_route=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')
export CYPRESS_BASE_URL=https://$console_route

# Set Cypress authentication username and password.
# Use the IDP once issue https://issues.redhat.com/browse/OCPBUGS-59366 is fixed.
#export CYPRESS_LOGIN_IDP=uiauto-htpasswd-idp
#export CYPRESS_LOGIN_USERS=${users}
export CYPRESS_LOGIN_IDP=kube:admin
export CYPRESS_LOGIN_USERS=kubeadmin:${kubeadmin_password}

# Run the Cypress tests.
export NO_COLOR=1
export CYPRESS_CACHE_FOLDER=/tmp/Cypress

# Install npm modules
ls -ltr
npm install

# Run the Cypress tests
npm run test-cypress-metrics
