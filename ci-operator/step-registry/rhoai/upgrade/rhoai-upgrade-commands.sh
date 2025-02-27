#!/bin/sh

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export KUBECONFIG=$SHARED_DIR/kubeconfig

# login to set up catalog source
OCP_CRED_USR="kubeadmin"
export OCP_CRED_USR
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
export OCP_CRED_PSW
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

OC_HOST=$(oc whoami --show-server)
OCP_CONSOLE=$(oc whoami --show-console)
RHODS_DASHBOARD="https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}{"\n"}')"
export OC_HOST
export OCP_CONSOLE
export RHODS_DASHBOARD

TEST_SUITE="PostUpgrade"
export TEST_SUITE

# Update subscription to use the custome catalog source
oc patch subscription rhods-operator -n redhat-ods-operator \
--type='merge' -p '{"spec":{"source":"rhoai-catalog-dev"}}'

sleep 120
echo "Checking CSV status"
oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec}'
echo "Checking version to upgrade: ${UPGRADE_VERSION}"

for i in {1..30}; do
    if oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installedCSV}' | grep -q "${UPGRADE_VERSION}"; then
        echo "Upgrade to new version complete, continue post upgrade testing"
        ./run_interop.sh
        exit $?
    fi
    echo "Waiting for upgrade..."
    sleep 20
done

echo "Error: Timeout reached, new version not found"
exit 1
