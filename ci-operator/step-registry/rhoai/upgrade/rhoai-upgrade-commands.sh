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

BUCKET_INFO="/tmp/secrets/ci"
ENDPOINT_1="$(cat ${BUCKET_INFO}/ENDPOINT_1)"
ENDPOINT_2="$(cat ${BUCKET_INFO}/ENDPOINT_2)"
REGION_1="$(cat ${BUCKET_INFO}/REGION_1)"
REGION_2="$(cat ${BUCKET_INFO}/REGION_2)"
NAME_1="$(cat ${BUCKET_INFO}/NAME_1)"
NAME_2="$(cat ${BUCKET_INFO}/NAME_2)"
NAME_3="$(cat ${BUCKET_INFO}/NAME_3)"
NAME_4="$(cat ${BUCKET_INFO}/NAME_4)"
NAME_5="$(cat ${BUCKET_INFO}/NAME_5)"

export ENDPOINT_1
export ENDPOINT_2
export REGION_1
export REGION_2
export NAME_1
export NAME_2
export NAME_3
export NAME_4
export NAME_5

TEST_SUITE="Post-Upgrade"
export TEST_SUITE

# enable the auto upgrade
oc patch subscription rhods-operator -n redhat-ods-operator --type='merge' -p '{"spec": {"installPlanApproval": "Automatic"}}'
oc get subscription rhods-operator -n redhat-ods-operator -o yaml | grep installPlanApproval

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: "fast"  # Change based on the desired channel
  installPlanApproval: Automatic
  name: rhods-operator
  source: rhoai-catalog-dev
  sourceNamespace: openshift-marketplace
EOF

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
