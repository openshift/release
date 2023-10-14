#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AAP_CONTAINERIZED_TEST_IMAGE_NAME="aap-secret"
AAP_CONTROLLER_NAME=${AAP_CONTROLLER_NAME:-'interop-automation-controller-instance'}
PROJECT_NAMESPACE=${PROJECT_NAMESPACE:-'aap'}
AAP_TESTS="tests/api"

echo "Login into the cluster"
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
oc login "https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443" \
  --username="kubeadmin" \
  --password="$(cat ${SHARED_DIR}/kubeadmin-password)" \
  --insecure-skip-tls-verify=true

echo "Wait for TOWER_HOST to be available"
x=0
TOWER_HOST=""
while [[ -z ${TOWER_HOST} && ${x} -lt 180 ]]; do
  echo "Waiting for URL..."
  sleep 10
  TOWER_HOST="$(oc get automationcontroller ${AAP_CONTROLLER_NAME} -n ${PROJECT_NAMESPACE} -o=jsonpath='{.status.URL}' --ignore-not-found)"
  x=$(( ${x} + 1 ))
done
echo "TOWER_HOST found: ${TOWER_HOST}"
TOWER_USER=$(oc get automationcontroller ${AAP_CONTROLLER_NAME} -n ${PROJECT_NAMESPACE} -o=jsonpath='{.status.adminUser}')
TOWER_SECRET_NAME=$(oc get automationcontroller ${AAP_CONTROLLER_NAME} -n ${PROJECT_NAMESPACE} -o=jsonpath='{.status.adminPasswordSecret}')
TOWER_PSW=$(oc get Secret ${TOWER_SECRET_NAME} -n ${PROJECT_NAMESPACE} -o=jsonpath='{.data.password}' | base64 -d)
TOWER_VERSION=$(oc get automationcontroller ${AAP_CONTROLLER_NAME} -n ${PROJECT_NAMESPACE} -o=jsonpath='{.status.version}')

echo "## Install yq"
wget --quiet https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /tmp/yq && chmod +x /tmp/yq

cat << EOF > /tmp/inventory
[automationcontroller]
${AAP_CONTROLLER_NAME} ansible_connection=ocp ansible_user=awx ansible_python_interpreter=/usr/bin/python3

[all:vars]
controller_base_url=${TOWER_HOST}
admin_password=${TOWER_PSW}
EOF

echo "Create secrets"
SECRETS_DIR="/tmp/secrets/ci"
oc create secret generic kubeconfig-secret --from-file $SHARED_DIR/kubeconfig
oc create secret docker-registry ${AAP_CONTAINERIZED_TEST_IMAGE_NAME} \
    --docker-server=quay.io \
    --docker-username="$(cat ${SECRETS_DIR}/QUAY_USER)" \
    --docker-password="$(cat ${SECRETS_DIR}/QUAY_PWD)"

echo "Parse credentials from secrets..."
sed 's/\\n/\
/g' ${SECRETS_DIR}/credentials > /tmp/credentials-temp.yml
/tmp/yq ".default.password = \"$TOWER_PSW\" | .default.username = \"$TOWER_USER\"" /tmp/credentials-temp.yml > /tmp/credentials.yml

echo "Run AAP Interop testing..."
POD_NAME=aap-tests-pod
CONTAINER_NAME=aap-tests-container

oc create configmap inventory-cm --from-file /tmp/inventory
oc create configmap credentials-cm --from-file /tmp/credentials.yml

cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: "${POD_NAME}"
spec:
  containers:
  - name: ${CONTAINER_NAME}
    image: quay.io/aap-ci/ansible-tests-integration-agent
    command: [ "/bin/sh", "-c", "./run_integration_tests.sh ${AAP_TESTS} && sleep 120" ]
    env:
    - name: KUBECONFIG
      value: "/kubeconfig/kubeconfig"
    - name: TOWER_HOST
      value: "${TOWER_HOST}"
    - name: INVENTORY
      value: "/home/jenkins/agent/inventory"
    - name: EXTRA_INVENTORY
      value: ""
    - name: API_CREDENTIALS
      value: "/home/jenkins/agent/credentials.yml"
    - name: TOWER_VERSION
      value: "${TOWER_VERSION}"
    - name: CONTROLLER_ARCH
      value: "x86_64"
    - name: INSTALL_TYPE
      value: ""
    - name: BASE_HUB_URL
      value: ""
    - name: TESTEXPR
      value: "yolo or ansible_integration"
    imagePullPolicy: Always
    resources:
      limits:
        cpu: 500m
        memory: 1000Mi
      requests:
        cpu: 200m
        memory: 500Mi
    securityContext:
      privileged: true
      readOnlyRootFilesystem: false
      runAsGroup: 0
      runAsUser: 0
    volumeMounts:
    - name: kubeconfig
      mountPath: /kubeconfig
    - name: inventory-cm
      mountPath: /home/jenkins/agent/inventory
      subPath: inventory
      readOnly: false
    - name: credentials-cm
      mountPath: /home/jenkins/agent/credentials.yml
      subPath: credentials.yml
      readOnly: false
  volumes:
  - name: kubeconfig
    secret:
      secretName: kubeconfig-secret
  - name: inventory-cm
    configMap:
      name: inventory-cm
  - name: credentials-cm
    configMap:
      name: credentials-cm
  imagePullSecrets:
  - name: ${AAP_CONTAINERIZED_TEST_IMAGE_NAME}
EOF

oc wait --for=condition=ContainersReady=true pod/${POD_NAME} --timeout=300s || true
oc describe pod ${POD_NAME}

x=0
while [[ ${x} -lt 180 ]]; do
  oc logs ${POD_NAME} | tail -n 20
  oc exec ${POD_NAME} -- ls / > $SHARED_DIR/Files

  if ! grep -q 'test-results.xml' $SHARED_DIR/Files ; then
    echo "${x} - Waiting for test results..."
    x=$(( ${x} + 1 ))
    sleep 30
  else
    echo "Test results found."
    break
  fi

done

oc logs ${POD_NAME}
oc cp ${POD_NAME}:/test-results.xml "${ARTIFACT_DIR}/junit_test-results.xml"

result=`cat ${ARTIFACT_DIR}/junit_test-results.xml | sed 's/"//g'`
echo "Result: ${result}"

if [[ "$result" =~ "errors=0" ]] && [[ "$result" =~ "failures=0" ]]; then
  echo "Test success.";
  exit 0
else
  echo "Test failed.";
  exit 1
fi