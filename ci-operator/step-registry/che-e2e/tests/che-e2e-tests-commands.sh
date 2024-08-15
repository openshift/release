#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Post test execution
trap 'sleep 2h' SIGINT SIGTERM ERR EXIT TERM

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export CONSOLE_URL
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_API_URL
IDP_USER="rosa-admin"
export IDP_USER
IDP_LOGIN_PATH=$(cat $SHARED_DIR/api.login)
IDP_PASSWD=$(echo "${IDP_LOGIN_PATH}" | grep -oP '(?<=-p\s)[^\s]+')
export IDP_PASSWD
CHE_NAMESPACE=test-run-interop
export CHE_NAMESPACE
POD_NAME=interop-wto
export POD_NAME

oc delete project $CHE_NAMESPACE || true
oc new-project $CHE_NAMESPACE
oc project $CHE_NAMESPACE

mkdir -p "${ARTIFACT_DIR}"/tests

echo "Creating test Pod: interop-wto"
cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: "${POD_NAME}"
  namespace: "${CHE_NAMESPACE}"
spec:
  volumes:
    - name: test-run-results
    - name: dshm
      emptyDir:
        medium: Memory
  containers:
    # container containing the tests
    - name: interop-wto-test
      image: quay.io/eclipse/e2e-che-interop:latest
      imagePullPolicy: Always
      env:
        - name: USERSTORY
          value: WebTerminalUnderAdmin
        - name: MOCHA_DIRECTORY
          value: web-terminal
        - name: NODE_TLS_REJECT_UNAUTHORIZED
          value: '0'
        - name: TS_SELENIUM_BASE_URL
          value: "${CONSOLE_URL}"
        - name: TS_SELENIUM_LOG_LEVEL
          value: TRACE
        - name: TS_SELENIUM_OCP_USERNAME
          value: "${IDP_USER}"
        - name: TS_SELENIUM_OCP_PASSWORD
          value: "${IDP_PASSWD}"
        - name: DELETE_WORKSPACE_ON_FAILED_TEST
          value: "true"
        - name: TS_OCP_LOGIN_PAGE_PROVIDER_TITLE
          value: "rosa-htpasswd"
      volumeMounts:
        - name: test-run-results
          mountPath: /tmp/e2e/report/
        - mountPath: /dev/shm
          name: dshm
      command: ["sh"]
      args:
        [
          "-c",
          "sleep 240",
        ]
      resources:
        requests:
          memory: "3Gi"
          cpu: "2"
        limits:
          memory: "4Gi"
          cpu: "2"
    # Download results
#    - name: download-reports
#      image: eeacms/rsync
#      imagePullPolicy: IfNotPresent
#      volumeMounts:
#        - name: test-run-results
#          mountPath: /tmp/e2e/report/
#      command: ["sh"]
#      args:
#        [
#          "-c",
#          "sleep 240",
#        ]
  restartPolicy: Never
EOF

oc wait --for=condition=ContainersReady=true pod/${POD_NAME} -n $CHE_NAMESPACE --timeout=300s || true
echo "Extracting logs into artifact dir"
oc cp interop-wto:/tmp/e2e/report/ $ARTIFACT_DIR/tests -n $CHE_NAMESPACE
oc rsync -n $CHE_NAMESPACE interop-wto:/tmp/e2e/report/ -c interop-wto-test $ARTIFACT_DIR/tests

## login for interop
#if test -f ${SHARED_DIR}/kubeadmin-password
#then
#  OCP_CRED_USR="kubeadmin"
#  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
#  oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true
#else #login for ROSA & Hypershift platforms
#  eval "$(cat "${SHARED_DIR}/api.login")"
#fi
