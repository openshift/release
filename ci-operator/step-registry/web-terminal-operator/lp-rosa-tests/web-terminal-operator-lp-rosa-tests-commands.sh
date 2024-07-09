#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



CONSOLE_URL=$(cat $SHARED_DIR/console.url)
export CONSOLE_URL
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export OCP_API_URL
IDP_USER="rosa-admin"
export IDP_USER
IDP_LOGIN_PATH=$(cat $SHARED_DIR/api.login)
IDP_PASSWD=$(echo "${IDP_LOGIN_PATH}" | grep -oP '(?<=-p\s)[^\s]+')
export IDP_PASSWD
export CHE_NAMESPACE
export TEST_POD_NAME

oc delete project $CHE_NAMESPACE || true
oc new-project $CHE_NAMESPACE
oc project $CHE_NAMESPACE

mkdir -p "${ARTIFACT_DIR}"/tests

echo "Creating test Pod: interop-wto"
cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: "${TEST_POD_NAME}"
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
        - name: SAVE_JUNIT_DATA
          value: true
      volumeMounts:
        - name: test-run-results
          mountPath: /tmp/e2e/report
        - mountPath: /dev/shm
          name: dshm
      resources:
        requests:
          memory: "3Gi"
          cpu: "2"
        limits:
          memory: "4Gi"
          cpu: "2"
    # Download results
    - name: download-reports
      image: eeacms/rsync
      imagePullPolicy: IfNotPresent
      volumeMounts:
        - name: test-run-results
          mountPath: /tmp/e2e/report
      command: ["sh"]
      args:
        [
          "-c",
          "sleep 600",
        ]
  restartPolicy: Never
EOF

oc wait --for=condition=ContainersReady=true pod/${TEST_POD_NAME} -n $CHE_NAMESPACE --timeout=300s || true
echo "Extracting logs into artifact dir"
oc -n $CHE_NAMESPACE cp ${TEST_POD_NAME}:/tmp/e2e/report -c download-reports "${ARTIFACT_DIR}/tests"

# Try to collect logs with rsync command
mkdir -p "${ARTIFACT_DIR}"/tests/debug
oc -n $CHE_NAMESPACE rsync TEST_POD_NAME:/tmp/e2e/report -c download-reports "${ARTIFACT_DIR}/tests/debug" || true