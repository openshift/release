#!/bin/bash

export HOME WORKSPACE CHROME_IMAGE CHROME_TAG
HOME=/tmp
WORKSPACE=$(pwd)
CHROME_IMAGE="quay.io/cloudservices/insights-chrome-frontend"
CHROME_TAG="f5f1929"

#Vault Secrets
export HAC_KC_SSO_URL HAC_KC_USERNAME HAC_KC_PASSWORD HAC_KC_REGISTRATION CYPRESS_GH_TOKEN CYPRESS_GH_PASSWORD CYPRESS_QUAY_TOKEN CYPRESS_RP_HAC CYPRESS_VC_KUBECONFIG
HAC_KC_SSO_URL=$(cat /usr/local/ci-secrets/devsandbox/sso_hostname)
HAC_KC_USERNAME=$(cat /usr/local/ci-secrets/devsandbox/username)
HAC_KC_PASSWORD=$(cat /usr/local/ci-secrets/devsandbox/new-password)
HAC_KC_REGISTRATION=$(cat /usr/local/ci-secrets/devsandbox/registration)

CYPRESS_GH_TOKEN=$(cat /usr/local/ci-secrets/github/github-token)
CYPRESS_GH_PASSWORD=$(cat /usr/local/ci-secrets/github/github-password)
CYPRESS_QUAY_TOKEN=$(cat /usr/local/ci-secrets/github/quay-token)
CYPRESS_RP_HAC=$(cat /usr/local/ci-secrets/github/report-portal-token-hac)
CYPRESS_VC_KUBECONFIG=$(cat /usr/local/ci-secrets/github/vc-kubeconfig)

#QONTRACT
export QONTRACT_PASSWORD QONTRACT_USERNAME QONTRACT_BASE_URL
QONTRACT_PASSWORD=$(cat /usr/local/ci-secrets/github/QONTRACT_PASSWORD)
QONTRACT_USERNAME=$(cat /usr/local/ci-secrets/github/QONTRACT_USERNAME)
QONTRACT_BASE_URL="https://app-interface.devshift.net/graphql"

#Ephemeral-bot
export OC_LOGIN_TOKEN OC_LOGIN_SERVER
OC_LOGIN_TOKEN=$(cat /usr/local/ci-secrets/ephemeralbot/oc-login-token)
OC_LOGIN_SERVER=$(cat /usr/local/ci-secrets/ephemeralbot/oc-login-server)

echo "Preparing bonfire config"
CONFIG_DIR=$(mktemp -d)
cat > "$CONFIG_DIR/config.yaml" << EOF
# Bonfire deployment configuration
# Defines where to fetch the file that defines application configs
appsFile:
  host: gitlab
  repo: insights-platform/cicd-common
  path: bonfire_configs/ephemeral_apps.yaml
# (optional) define any apps locally. An app defined here with <name> will override config for app
# <name> in above fetched config.
apps:
- name: insights-ephemeral
  components:
    - name: frontend-configs
      host: github
      repo: redhat-hac-qe/frontend-configs
      path: deploy/deploy.yaml
EOF

echo "Installing bonfire."
export LANG LC_ALL
LANG=en_US.utf-8
LC_ALL=en_US.utf-8

python3 -m venv .bonfire_venv
source .bonfire_venv/bin/activate

python3 -m pip install --upgrade pip 'setuptools<58' wheel
python3 -m pip install --upgrade 'crc-bonfire>=4.10.4'

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

# Deploy hac-dev
echo "Deploy hac-dev"
bonfire deploy -c "$CONFIG_DIR/config.yaml" \
        hac \
        --frontends true \
        --source=appsre \
        --clowd-env ${ENV_NAME} \
        --set-image-tag ${CHROME_IMAGE}=${CHROME_TAG} \
        --namespace ${NAMESPACE} \
        --timeout 1200

# Call the keycloak API and add a user
B64_USER=$(oc get secret ${ENV_NAME}-keycloak -o json | jq '.data.username'| tr -d '"')
B64_PASS=$(oc get secret ${ENV_NAME}-keycloak -o json | jq '.data.password' | tr -d '"')

# These ENVs are populated in the Jenkins job by Vault secrets
curl -o keycloak.py https://raw.githubusercontent.com/openshift/hac-dev/main/tmp/keycloak.py
python keycloak.py $HAC_KC_SSO_URL $HAC_KC_USERNAME $HAC_KC_PASSWORD $B64_USER $B64_PASS $HAC_KC_REGISTRATION

export CYPRESS_PERIODIC_RUN CYPRESS_HAC_BASE_URL CYPRESS_USERNAME CYPRESS_PASSWORD CYPRESS_RP_TOKEN
CYPRESS_PERIODIC_RUN=true
CYPRESS_HAC_BASE_URL=https://${HOSTNAME}/hac/stonesoup
CYPRESS_USERNAME=`echo ${B64_USER} | base64 -d`
CYPRESS_PASSWORD=`echo ${B64_PASS} | base64 -d`
CYPRESS_RP_TOKEN=${CYPRESS_RP_HAC}

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
