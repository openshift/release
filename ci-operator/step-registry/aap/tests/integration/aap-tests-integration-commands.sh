#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AAP_CONTAINERIZED_TEST_IMAGE_NAME="aap-secret"
AAP_CONTROLLER_NAME="interop-automation-controller-instance"
NAMESPACE="aap"
AAP_TESTS="tests/api"
POD_NAME=aap-tests-pod
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
oc login "https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443" \
  --username="kubeadmin" \
  --password="$(cat ${SHARED_DIR}/kubeadmin-password)" \
  --insecure-skip-tls-verify=true

x=0
TOWER_HOST=""
while [[ -z ${TOWER_HOST} && ${x} -lt 180 ]]; do
  echo "Waiting for TOWER_HOST to be available..."
  sleep 10
  TOWER_HOST="$(oc get automationcontroller ${AAP_CONTROLLER_NAME} -n ${NAMESPACE} -o=jsonpath='{.status.URL}' --ignore-not-found)"
  x=$(( ${x} + 1 ))
done
echo "TOWER_HOST found: ${TOWER_HOST}"
TOWER_USER=$(oc get automationcontroller ${AAP_CONTROLLER_NAME} -n ${NAMESPACE} -o=jsonpath='{.status.adminUser}')
TOWER_SECRET_NAME=$(oc get automationcontroller ${AAP_CONTROLLER_NAME} -n ${NAMESPACE} -o=jsonpath='{.status.adminPasswordSecret}')
TOWER_PSW=$(oc get Secret ${TOWER_SECRET_NAME} -n ${NAMESPACE} -o=jsonpath='{.data.password}' | base64 -d)
TOWER_VERSION=$(oc get automationcontroller ${AAP_CONTROLLER_NAME} -n ${NAMESPACE} -o=jsonpath='{.status.version}')

wget --quiet https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /tmp/yq && chmod +x /tmp/yq

cat << EOF > /tmp/inventory
[automationcontroller]
${AAP_CONTROLLER_NAME} ansible_connection=ocp ansible_user=awx ansible_python_interpreter=/usr/bin/python3

[all:vars]
controller_base_url=${TOWER_HOST}
admin_password=${TOWER_PSW}
EOF

SECRETS_DIR="/tmp/secrets/ci"
oc create secret generic kubeconfig-secret -n $NAMESPACE --from-file $SHARED_DIR/kubeconfig
oc create secret docker-registry -n $NAMESPACE ${AAP_CONTAINERIZED_TEST_IMAGE_NAME} \
    --docker-server=quay.io \
    --docker-username="$(cat ${SECRETS_DIR}/QUAY_USER)" \
    --docker-password="$(cat ${SECRETS_DIR}/QUAY_PWD)"

sed 's/<nl>/\
/g' ${SECRETS_DIR}/credentials > /tmp/credentials-temp.yml

sed -i 's/\\\\n/\\n/g' /tmp/credentials-temp.yml

sed -i 's/\\"/"/g' /tmp/credentials-temp.yml

/tmp/yq ".aapqa_secrets" /tmp/credentials-temp.yml > /tmp/credentials-formatted.yml
/tmp/yq ".default.password = \"$TOWER_PSW\" | .default.username = \"$TOWER_USER\"" /tmp/credentials-formatted.yml > /tmp/credentials.yml

oc create configmap inventory-cm -n $NAMESPACE --from-file /tmp/inventory
oc create secret generic credentials-secret -n $NAMESPACE --from-file /tmp/credentials.yml

cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: test-container
    image: quay.io/aap-ci/ansible-tests-integration-agent:latest
    command: [ "/bin/sh", "-c", "./run_integration_tests.sh ${AAP_TESTS} && echo && echo 'Test run ended' && sleep 120" ]
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
    - name: PAT_GITHUB
      value: "$(cat ${SECRETS_DIR}/PAT_GITHUB)"
    imagePullPolicy: Always
    resources:
      limits:
        cpu: 500m
        memory: 1000Mi
      requests:
        cpu: 300m
        memory: 500Mi
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
      runAsNonRoot: true
      seccompProfile:
        type: "RuntimeDefault"
      readOnlyRootFilesystem: false
      runAsGroup: 0
    volumeMounts:
    - name: kubeconfig
      mountPath: /kubeconfig
    - name: inventory-cm
      mountPath: /home/jenkins/agent/inventory
      subPath: inventory
      readOnly: false
    - name: credentials-secret
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
  - name: credentials-secret
    secret:
      secretName: credentials-secret
  imagePullSecrets:
  - name: ${AAP_CONTAINERIZED_TEST_IMAGE_NAME}
EOF

oc wait --for=condition=ContainersReady=true pod/${POD_NAME} -n $NAMESPACE --timeout=300s || true
oc describe pod ${POD_NAME} -n $NAMESPACE

while : ; do
  oc -n $NAMESPACE logs ${POD_NAME} | tail -n 40
  oc -n $NAMESPACE exec ${POD_NAME} -- ls /home/jenkins/agent > $SHARED_DIR/Files
  
  if ! grep -q 'test-results.xml' $SHARED_DIR/Files ; then
    echo
    echo "Waiting for test results..."
    sleep 30
  else
    echo
    echo "Test results found."
    break
  fi
done

oc -n $NAMESPACE logs ${POD_NAME} | tail
oc -n $NAMESPACE cp ${POD_NAME}:/home/jenkins/agent/test-results.xml "${ARTIFACT_DIR}/junit_test-results.xml"
cat ${ARTIFACT_DIR}/junit_test-results.xml | sed 's/"//g'