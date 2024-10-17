#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

echo "This is the start SHARED_DIR: ${SHARED_DIR}"

#SECRETS_DIR="/tmp/secrets"
#export KUBECONFIG="{SHARED_DIR}/.kube/config"

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"

echo "Login as Kubeadmin to the test cluster at ${API_URL}..."
mkdir -p $SHARED_DIR/.kube
touch $SHARED_DIR/.kube/config
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

OC_HOST="$(oc whoami --show-server)"
#CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id") || true
#CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name") || true
if [[ -e ${SHARED_DIR}/metadata.json ]]; then
  # for OCP
  CLUSTER_ID=$(jq '.clusterID' ${SHARED_DIR}/metadata.json)
  CLUSTER_NAME=$(jq '.clusterName' ${SHARED_DIR}/metadata.json)
elif [[ -e ${SHARED_DIR}/cluster_id ]]; then
  # for ManagedCluster, e.g. ROSA
  echo "Reading infra id from file infra_id"
  CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
else
  echo "Error: No cluster id found, exit now"
  exit 1
fi

#ROBOT_EXTRA_ARGS="-i $TEST_MARKER -e AutomationBug -e Resources-GPU -e Resources-2GPUS"
ROBOT_EXTRA_ARGS="-i ODS-127"
RUN_SCRIPT_ARGS="--skip-oclogin true --set-urls-variables true --test-artifact-dir ${ARTIFACT_DIR}/results"

export OC_HOST
export CLUSTER_NAME
export CLUSTER_ID
export ROBOT_EXTRA_ARGS
export RUN_SCRIPT_ARGS

mkdir "$ARTIFACT_DIR/results"

function createHtpasswdIDP(){
  htpasswd -b -B -c $ARTIFACT_DIR/users.txt htpasswd-cluster-admin-user rhodsPW#123456
  oc delete secret htpasswd-bind-password --ignore-not-found -n openshift-config
  oc create secret generic htpasswd-bind-password --from-file=htpasswd=$ARTIFACT_DIR/users.txt -n openshift-config
  oc delete identity htpasswd-cluster-admin:htpasswd-cluster-admin-user --ignore-not-found
  oc patch oauth cluster --type json -p '[{op: add, path: /spec/identityProviders, value: []}]'
  oc patch oauth cluster --type json -p '[{"op": "add", "path": "/spec/identityProviders/-", "value": {"name":"htpasswd-cluster-admin","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpasswd-bind-password"}}}}]'
  oc adm groups new dedicated-admins
  oc delete user htpasswd-cluster-admin-user --ignore-not-found -n openshift-config
  oc create user htpasswd-cluster-admin-user
  oc adm groups add-users dedicated-admins htpasswd-cluster-admin-user
  oc adm policy add-cluster-role-to-group cluster-admin dedicated-admins
  oc adm policy add-cluster-role-to-user cluster-admin htpasswd-cluster-admin-user
}

function createIDP(){
  echo "Clone the ods-install repo"
  git clone git@gitlab.cee.redhat.com:ods/ods-install.git
  cd ods-install
  ./odstest --install-identity-providers
}

function updateTestConfig(){
  echo "INFO: getting RHODS URLs from the cluster as per --set-urls-variables"
  ocp_console=$(oc whoami --show-console)
  rhods_dashboard="https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}{"\n"}')"
  api_server=$(oc whoami --show-server)
  prom_server="https://$(oc get route prometheus -n redhat-ods-monitoring -o jsonpath='{.spec.host}{"\n"}')"
  prom_token="$(oc create token prometheus -n redhat-ods-monitoring --duration 6h)"
  ldap_pw=rhodsPW#1

  export api_server
  export ocp_console
  export rhods_dashboard
  export prom_server
  export prom_token
  export ldap_pw=$ldap_pw

  # update test-variables.yml
  yq -i '.OCP_ADMIN_USER.AUTH_TYPE="htpasswd-cluster-admin"' test-variables.yml
  yq -i '.OCP_ADMIN_USER.USERNAME="htpasswd-cluster-admin-user"' test-variables.yml
  yq -i '.OCP_ADMIN_USER.PASSWORD="rhodsPW#123456"' test-variables.yml

  yq -i '.TEST_USER.AUTH_TYPE="ldap-provider-qe"' test-variables.yml
  yq -i '.TEST_USER.USERNAME="ldap-admin1"' test-variables.yml
  yq -i '.TEST_USER.PASSWORD=env(ldap_pw)' test-variables.yml
  
  yq -i '.TEST_USER_2.AUTH_TYPE="ldap-provider-qe"' test-variables.yml
  yq -i '.TEST_USER_2.USERNAME="ldap-admin2"' test-variables.yml
  yq -i '.TEST_USER_2.PASSWORD=env(ldap_pw)' test-variables.yml
  
  yq -i '.TEST_USER_3.AUTH_TYPE="ldap-provider-qe"' test-variables.yml
  yq -i '.TEST_USER_3.USERNAME="ldap-user2"' test-variables.yml
  yq -i '.TEST_USER_3.PASSWORD=env(ldap_pw)' test-variables.yml
  
  yq -i '.TEST_USER_4.AUTH_TYPE="ldap-provider-qe"' test-variables.yml
  yq -i '.TEST_USER_4.USERNAME="ldap-user9"' test-variables.yml
  yq -i '.TEST_USER_4.PASSWORD=env(ldap_pw)' test-variables.yml

  yq -i '.OCP_API_URL=env(api_server)' test-variables.yml
  yq -i '.OCP_CONSOLE_URL=env(ocp_console)' test-variables.yml
  yq -i '.ODH_DASHBOARD_URL=env(rhods_dashboard)' test-variables.yml
  yq -i '.RHODS_PROMETHEUS_URL=env(prom_server)' test-variables.yml
  yq -i '.RHODS_PROMETHEUS_TOKEN=env(prom_token)' test-variables.yml
}

echo "Starting to generate Test Config File..."

echo "Create Htpasswd Admin User in OCP cluster"
#createHtpasswdIDP

echo "Create IDP"
#createIDP

echo "Update local test-variables.yml"
updateTestConfig

# running RHOAI testsuite
./ods_ci/run_robot_test.sh --skip-install ${RUN_SCRIPT_ARGS} --extra-robot-args "${ROBOT_EXTRA_ARGS}"
