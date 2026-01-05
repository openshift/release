#!/bin/bash
set -o nounset
set -o pipefail

# This script is designed to run as a step in Prow CI (OpenShift CI) jobs.
# We intentionally use 'exit 0' instead of 'exit 1' for failures to prevent
# blocking subsequent test steps in the CI pipeline. When a step exits with
# a non-zero code, the job stops and doesn't proceed to run subsequent steps.
# Since we're adding multiple test steps for different components, we want
# all steps to run regardless of individual step failures. Test failures
# can still be identified and analyzed through junit reports which are
# stored in the artifact directory and job status. A final step can be added 
# to parse the junit reports and fail the job if any tests fail.

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
  CYPRESS_SKIP_TESTS
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
  exit 0
fi

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "Error: Kubeconfig file ${KUBECONFIG} does not exist"
  exit 0
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

# Fetch the OpenShift version and extract the minor version
oc_version_minor=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d . -f 2)

echo "Detected OpenShift minor version: $oc_version_minor"

# Define the repository URL and target directory
repo_url="https://github.com/openshift/distributed-tracing-console-plugin.git"
target_dir="/tmp/distributed-tracing-console-plugin"

# Clone the repository and checkout the appropriate branch based on the OpenShift version
if [[ "$oc_version_minor" -ge 19 ]]; then
  echo "OpenShift version is 4.$oc_version_minor or greater. Cloning the main branch."
  git clone "$repo_url" "$target_dir"
  if [ $? -eq 0 ]; then
    cd "$target_dir/tests" || exit 0
    git checkout release-1.0
    echo "Successfully cloned the repository and changed directory to $target_dir/tests."
  else
    echo "Error cloning the repository."
    exit 0
  fi
else
  echo "OpenShift version is less than 4.19. Cloning and checking out the release-0.4 branch."
  git clone "$repo_url" "$target_dir"
  if [ $? -eq 0 ]; then
    cd "$target_dir/tests" || exit 0
    git checkout release-0.4
    if [ $? -eq 0 ]; then
      echo "Successfully cloned the repository, changed directory to $target_dir/tests, and checked out the release-0.4 branch."
    else
      echo "Error checking out the release-0.4 branch."
      exit 0
    fi
  else
    echo "Error cloning the repository."
    exit 0
  fi
fi

# Install npm modules
npm install || true

# Run the Cypress tests with grep filter if CYPRESS_SKIP_TESTS is set
if [[ -n "${CYPRESS_SKIP_TESTS:-}" ]]; then
  echo "Running Cypress tests with grep pattern: ${CYPRESS_SKIP_TESTS}"
  npx cypress run --browser chrome --headless --env grep="${CYPRESS_SKIP_TESTS}",grepOmitFiltered=true || true
else
  echo "Running all Cypress tests"
  npm run test-cypress-console-headless || true
fi
