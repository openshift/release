#!/bin/bash

export HOME WORKSPACE CHROME_IMAGE CHROME_TAG
HOME=/tmp
WORKSPACE=$(pwd)

#Vault Secrets
export HAC_KC_SSO_URL HAC_KC_USERNAME HAC_KC_PASSWORD HAC_KC_REGISTRATION CYPRESS_GH_TOKEN CYPRESS_GH_PASSWORD CYPRESS_QUAY_TOKEN CYPRESS_RP_HAC CYPRESS_VC_KUBECONFIG CYPRESS_SNYK_TOKEN
HAC_KC_SSO_URL=$(cat /usr/local/ci-secrets/devsandbox/sso_hostname)
HAC_KC_USERNAME=$(cat /usr/local/ci-secrets/devsandbox/username)
HAC_KC_PASSWORD=$(cat /usr/local/ci-secrets/devsandbox/new-password)
HAC_KC_REGISTRATION=$(cat /usr/local/ci-secrets/devsandbox/registration)

CYPRESS_GH_TOKEN=$(cat /usr/local/ci-secrets/github/github-token)
CYPRESS_GH_PASSWORD=$(cat /usr/local/ci-secrets/github/github-password)
CYPRESS_QUAY_TOKEN=$(cat /usr/local/ci-secrets/github/quay-token)
CYPRESS_RP_HAC=$(cat /usr/local/ci-secrets/github/report-portal-token-hac)
CYPRESS_VC_KUBECONFIG=$(cat /usr/local/ci-secrets/github/vc-kubeconfig)
CYPRESS_SNYK_TOKEN=$(cat /usr/local/ci-secrets/github/snyk_token)

#QONTRACT
export QONTRACT_PASSWORD QONTRACT_USERNAME QONTRACT_BASE_URL
QONTRACT_PASSWORD=$(cat /usr/local/ci-secrets/github/QONTRACT_PASSWORD)
QONTRACT_USERNAME=$(cat /usr/local/ci-secrets/github/QONTRACT_USERNAME)
QONTRACT_BASE_URL="https://app-interface.devshift.net/graphql"

#Ephemeral-bot
export OC_LOGIN_TOKEN OC_LOGIN_SERVER
OC_LOGIN_TOKEN=$(cat /usr/local/ci-secrets/ephemeralbot/oc-login-token)
OC_LOGIN_SERVER=$(cat /usr/local/ci-secrets/ephemeralbot/oc-login-server)

echo "Installing bonfire."
export LANG LC_ALL
LANG=en_US.utf-8
LC_ALL=en_US.utf-8

python3 -m venv .bonfire_venv
source .bonfire_venv/bin/activate

python3 -m pip install --upgrade pip 'setuptools<58' wheel
python3 -m pip install --upgrade 'crc-bonfire>=4.18.0'

export KUBECONFIG_DIR KUBECONFIG
KUBECONFIG_DIR="$WORKSPACE/.kube"
KUBECONFIG="$KUBECONFIG_DIR/config"
rm -fr $KUBECONFIG_DIR
mkdir $KUBECONFIG_DIR

echo "login to Ephemeral cluster"
oc login --token=$OC_LOGIN_TOKEN --server=$OC_LOGIN_SERVER

# Get a namespace in the eph cluster and set vars accordingly
NAMESPACE=$(bonfire namespace reserve -f)
ENV_NAME=env-${NAMESPACE}
oc project ${NAMESPACE}
HOSTNAME=$(oc get feenv ${ENV_NAME} -o json | jq ".spec.hostname" | tr -d '"')

# Temp: setup proxy and patch SSO for devsandbox
oc patch feenv ${ENV_NAME} --type merge  -p '{"spec":{"sso": "'$HAC_KC_SSO_URL'" }}'
oc process -f https://raw.githubusercontent.com/openshift/hac-dev/main/tmp/hac-proxy.yaml -n ${NAMESPACE} -p NAMESPACE=${NAMESPACE} -p ENV_NAME=${ENV_NAME} -p HOSTNAME=${HOSTNAME} | oc create -f -

# Omit some default bonfire frontend dependencies
export BONFIRE_FRONTEND_DEPENDENCIES=chrome-service,insights-chrome

# Deploy hac-dev
echo "Deploy hac-dev"
bonfire deploy hac \
        --frontends true \
        --source=appsre \
        --clowd-env ${ENV_NAME} \
        --namespace ${NAMESPACE} \
        --timeout 1200

# Call the keycloak API and add a user
B64_USER=$(oc get secret ${ENV_NAME}-keycloak -o json | jq '.data.username'| tr -d '"')
B64_PASS=$(oc get secret ${ENV_NAME}-keycloak -o json | jq '.data.password' | tr -d '"')

# These ENVs are populated in the Jenkins job by Vault secrets
curl -o keycloak.py https://raw.githubusercontent.com/openshift/hac-dev/main/tmp/keycloak.py
python keycloak.py $HAC_KC_SSO_URL $HAC_KC_USERNAME $HAC_KC_PASSWORD $B64_USER $B64_PASS $HAC_KC_REGISTRATION

export CYPRESS_PERIODIC_RUN CYPRESS_HAC_BASE_URL CYPRESS_USERNAME CYPRESS_PASSWORD CYPRESS_RP_TOKEN CYPRESS_SSO_URL
CYPRESS_PERIODIC_RUN=true
CYPRESS_HAC_BASE_URL=https://${HOSTNAME}/preview/application-pipeline
CYPRESS_USERNAME=`echo ${B64_USER} | base64 -d`
CYPRESS_PASSWORD=`echo ${B64_PASS} | base64 -d`
CYPRESS_RP_TOKEN=${CYPRESS_RP_HAC}
CYPRESS_SSO_URL=${HAC_KC_SSO_URL}

set +e
# Run Cypress Tests
TEST_RUN=0
cd /tmp/e2e || { echo "/tmp/e2e doesn't exists"; exit 1; }
npm run cy:run || TEST_RUN=1

cp -a /tmp/e2e/cypress/* ${ARTIFACT_DIR}

echo "Releasing bonfire namespace"
bonfire namespace release ${NAMESPACE} -f

# Teardown
exit $TEST_RUN
