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

# Set Kubeconfig var for Cypress.
cp -L $KUBECONFIG /tmp/kubeconfig && export CYPRESS_KUBECONFIG_PATH=/tmp/kubeconfig

# Set Cypress base URL var.
console_route=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')
export CYPRESS_BASE_URL=https://$console_route

# Set Cypress authentication username and password.
export CYPRESS_LOGIN_IDP=uiauto-htpasswd-idp
export CYPRESS_LOGIN_USERS=${users}

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
    cd "$target_dir/tests"
    echo "Successfully cloned the repository and changed directory to $target_dir/tests."
  else
    echo "Error cloning the repository."
    exit 1
  fi
else
  echo "OpenShift version is less than 4.19. Cloning and checking out the release-0.4 branch."
  git clone "$repo_url" "$target_dir"
  if [ $? -eq 0 ]; then
    cd "$target_dir/tests"
    git checkout release-0.4
    if [ $? -eq 0 ]; then
      echo "Successfully cloned the repository, changed directory to $target_dir/tests, and checked out the release-0.4 branch."
    else
      echo "Error checking out the release-0.4 branch."
      exit 1
    fi
  else
    echo "Error cloning the repository."
    exit 1
  fi
fi

# Install npm modules
ls -ltr
npm install

# Run the Cypress tests
npm run test-cypress-console-headless
