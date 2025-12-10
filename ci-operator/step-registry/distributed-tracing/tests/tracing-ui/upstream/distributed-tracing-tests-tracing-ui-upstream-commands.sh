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
  CYPRESS_DT_CONSOLE_IMAGE
  CYPRESS_COO_NAMESPACE
  CYPRESS_LIGHTSPEED_CONSOLE_IMAGE
  CYPRESS_LIGHTSPEED_PROVIDER_URL
  CYPRESS_LIGHTSPEED_PROVIDER_TOKEN
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
  exit 1
fi

if [[ ! -f "${KUBEADMIN_PASSWORD_FILE}" ]]; then
  echo "Error: Kubeadmin password file ${KUBEADMIN_PASSWORD_FILE} does not exist"
  exit 1
fi

kubeadmin_password=$(cat "${KUBEADMIN_PASSWORD_FILE}")
echo "Successfully read kubeadmin password from ${KUBEADMIN_PASSWORD_FILE}"

# Read Lightspeed credentials from vault if not already set
LIGHTSPEED_PROVIDER_TOKEN_FILE="/var/run/vault/dt-secrets/lightspeed-provider-token"
LIGHTSPEED_PROVIDER_URL_FILE="/var/run/vault/dt-secrets/lightspeed-provider-url"

if [[ -z "${CYPRESS_LIGHTSPEED_PROVIDER_TOKEN:-}" ]]; then
  if [[ -f "${LIGHTSPEED_PROVIDER_TOKEN_FILE}" ]]; then
    CYPRESS_LIGHTSPEED_PROVIDER_TOKEN=$(cat "${LIGHTSPEED_PROVIDER_TOKEN_FILE}")
    export CYPRESS_LIGHTSPEED_PROVIDER_TOKEN
    echo "Successfully read Lightspeed provider token from ${LIGHTSPEED_PROVIDER_TOKEN_FILE}"
  else
    echo "Warning: Lightspeed provider token file ${LIGHTSPEED_PROVIDER_TOKEN_FILE} does not exist"
  fi
fi

if [[ -z "${CYPRESS_LIGHTSPEED_PROVIDER_URL:-}" ]]; then
  if [[ -f "${LIGHTSPEED_PROVIDER_URL_FILE}" ]]; then
    CYPRESS_LIGHTSPEED_PROVIDER_URL=$(cat "${LIGHTSPEED_PROVIDER_URL_FILE}")
    export CYPRESS_LIGHTSPEED_PROVIDER_URL
    echo "Successfully read Lightspeed provider URL from ${LIGHTSPEED_PROVIDER_URL_FILE}"
  else
    echo "Warning: Lightspeed provider URL file ${LIGHTSPEED_PROVIDER_URL_FILE} does not exist"
  fi
fi

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
  if [ -d "gui_test_screenshots" ]; then
    cp -r gui_test_screenshots "${ARTIFACT_DIR}/gui_test_screenshots"
    echo "Artifacts copied successfully."
  else
    echo "Directory gui_test_screenshots does not exist. Nothing to copy."
  fi
}

## Add IDP for testing
# prepare users
users=""
htpass_file=/tmp/users.htpasswd

for i in $(seq 1 5); do
    username="uiauto-test-${i}"
    password=$(tr </dev/urandom -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
    users+="${username}:${password},"
    if [ -f "${htpass_file}" ]; then
        htpasswd -B -b ${htpass_file} "${username}" "${password}"
    else
        htpasswd -c -B -b ${htpass_file} "${username}" "${password}"
    fi
done

# remove trailing ',' for case parsing
users=${users%?}

# current generation
gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')

# add users to cluster
oc create secret generic uiauto-htpass-secret --from-file=htpasswd=${htpass_file} -n openshift-config
oc patch oauth cluster --type='json' -p='[{"op": "add", "path": "/spec/identityProviders", "value": [{"type": "HTPasswd", "name": "uiauto-htpasswd-idp", "mappingMethod": "claim", "htpasswd":{"fileData":{"name": "uiauto-htpass-secret"}}}]}]'

## wait for oauth-openshift to rollout
wait_auth=true
expected_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.spec.replicas}')
while $wait_auth; do
    available_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.availableReplicas}')
    new_gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
    if [[ $expected_replicas == "$available_replicas" && $((new_gen)) -gt $((gen)) ]]; then
        wait_auth=false
    else
        sleep 10
    fi
done
echo "authentication operator finished updating"

# Copy the artifacts to the aritfact directory at the end of the test run.
trap copyArtifacts EXIT

# Validate KUBECONFIG
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "Error: KUBECONFIG variable is not set"
  exit 1
fi

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "Error: Kubeconfig file ${KUBECONFIG} does not exist"
  exit 1
fi

# Set Kubeconfig var for Cypress.
export CYPRESS_KUBECONFIG_PATH=$KUBECONFIG

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
npm install

# Run the Cypress tests
npm run test-cypress-console-headless
