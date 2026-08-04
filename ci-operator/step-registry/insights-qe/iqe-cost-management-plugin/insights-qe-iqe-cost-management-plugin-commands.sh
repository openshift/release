#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Run Cost Management Interop testing..."
SECRETS_DIR="/tmp/secrets/ci"

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
OCP_CRED_USR="kubeadmin"
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true

# create secret for cluster login
oc create secret generic kubeconfig-secret --from-file $SHARED_DIR/kubeconfig

# create secret for pulling quay image
username="$(cat ${SECRETS_DIR}/username)"
password="$(cat ${SECRETS_DIR}/password)"
oc create secret docker-registry cspi-pull-secret --docker-server=quay.io \
--docker-username=${username} --docker-password=${password}

# create secret for vault access
oc apply -f $SECRETS_DIR/insights-vault-pull

cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: insights-pod
spec:
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: insights-container
    image: quay.io/cloudservices/iqe-tests:cost-management
    command: ["/bin/sh", "-c"]
    args: ["iqe tests plugin cost_management -m cost_interop -vv --junitxml=test_run.xml && sleep 240"]
    env:
    - name: KUBECONFIG
      value: "/kubeconfig/kubeconfig"
    - name: IQE_MARKER_EXPRESSION
      value: core
    - name: IQE_PLUGINS
      value: cost-management
    - name: IQE_LOG_LEVEL
      value: INFO
    - name: IQE_PARALLEL_ENABLED
      value: "false"
    - name: IQE_PARALLEL_WORKER_COUNT
      value: "2"
    - name: IQE_TESTS_LOCAL_CONF_PATH
      value: "None"
    - name: ENV_FOR_DYNACONF
      value: prod
    - name: DYNACONF_IBUTSU_URL
      value: https://ibutsu-api.apps.ocp4.prod.psi.redhat.com/
    - name: DYNACONF_IQE_VAULT_LOADER_ENABLED
      value: "true"
    - name: DYNACONF_IQE_VAULT_MOUNT_POINT
      valueFrom:
        secretKeyRef:
          key: mountPoint
          name: iqe-vault
    - name: DYNACONF_IQE_VAULT_URL
      valueFrom:
        secretKeyRef:
          key: url
          name: iqe-vault
    - name: DYNACONF_IQE_VAULT_ROLE_ID
      valueFrom:
        secretKeyRef:
          key: roleId
          name: iqe-vault
    - name: DYNACONF_IQE_VAULT_SECRET_ID
      valueFrom:
        secretKeyRef:
          key: secretId
          name: iqe-vault
    imagePullPolicy: Always
    resources:
      limits:
        cpu: 500m
        memory: 2Gi
      requests:
        cpu: 200m
        memory: 2Gi
    securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities:
          drop:
            - ALL
    volumeMounts:
    - name: kubeconfig
      mountPath: /kubeconfig
  volumes:
  - name: kubeconfig
    secret:
      secretName: kubeconfig-secret
  imagePullSecrets:
  - name: cspi-pull-secret
EOF

oc wait --for=condition=ContainersReady=true pod/insights-pod --timeout=200s || true
oc get pod insights-pod

echo "Waiting for test results..."

while true; do
  oc exec insights-pod -- ls . > $SHARED_DIR/Files
  if ! grep -q 'test_run.xml' $SHARED_DIR/Files ; then
    sleep 5
  else
    break
  fi
done

echo "Retrieve test results..."
oc cp insights-pod:test_run.xml "${ARTIFACT_DIR}/junit_test_run.xml"

result=`cat ${ARTIFACT_DIR}/junit_test_run.xml | sed 's/"//g'`

if [[ "$result" =~ "errors=0" ]] && [[ "$result" =~ "failures=0" ]]; then
  echo "Test done."; exit 0
else
  echo "Test failed."; exit 1
fi
