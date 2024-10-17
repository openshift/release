#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Run JWS Interop testing..."
SECRETS_DIR="/tmp/secrets/tests"
mkdir -p  ${ARTIFACT_DIR}/jws_artifacts/jws-5
export KUBECONFIG=$SHARED_DIR/kubeconfig


CONSOLE_URL=$(cat $SHARED_DIR/console.url)
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
OCP_CRED_USR="kubeadmin"
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"

oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true

OCP_API_TOKEN=$(oc whoami -t)

export OCP_API_TOKEN

username="$(cat ${SECRETS_DIR}/username)"
password="$(cat ${SECRETS_DIR}/password)"

#namespaces used for running jws tests on test cluster
namespaces=("$JWS_TEST_POD_NAMESPACE" "$JWS_TEST_NAMESPACE" "$JWS_TEST_NAMESPACE-build")

#create required secrets in all the relevant namespaces
for namespace in "${namespaces[@]}" ; do
    oc create namespace $namespace
    echo "create cspi-pull-secret in namespace: $namespace"
    oc create secret docker-registry cspi-pull-secret --docker-server=quay.io \
       --docker-username=${username} --docker-password=${password} \
       --namespace=$namespace

    oc get secrets installation-pull-secrets -n openshift-image-registry -o json \
      | jq 'del(.metadata["namespace","creationTimestamp","resourceVersion","selfLink","uid","annotations"])' \
      | oc apply -n $namespace -f -

    oc create secret generic kubeconfig-secret --from-file $SHARED_DIR/kubeconfig --namespace=$namespace
done

OPENSHIFT_PROJECT_NAME="$(echo ${JWS_TEST_NAMESPACE})"
IMAGE_REGISTRY="$(echo ${JWS_IMAGE_REGISTRY})"

oc project $JWS_TEST_POD_NAMESPACE

cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: jws-test-pod
spec:
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: web
    image: quay.io/jbossqe-jws/pit-openshift-ews-tests
    command: ["/bin/sh", "-c"]
    args: ["./opt/openshift-jws-tests/entrypoint.sh"]
    env:
    - name: KUBECONFIG
      value: "/kubeconfig/kubeconfig"
    - name: OPENSHIFT_PROJECT_NAME
      value: "${OPENSHIFT_PROJECT_NAME}"
    - name: OPENSHIFT_CLUSTER_URL
      value: "${OCP_API_URL}"
    - name: OPENSHIFT_AUTH_TOKEN
      value: "${OCP_API_TOKEN}"
    - name: OPENSHIFT_USERNAME
      value: "${OCP_CRED_USR}"
    - name: JWS_IMAGE_REGISTRY
      value: "${IMAGE_REGISTRY}"
    imagePullPolicy: Always
    resources:
      limits:
        cpu: 500m
        memory: 1000Mi
      requests:
        cpu: 200m
        memory: 500Mi
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
  - name: installation-pull-secrets
EOF

oc wait --for=condition=ContainersReady=true pod/jws-test-pod --timeout=200s || true
oc wait --for=condition=complete pod/jws-test-pod --timeout=120m || true

echo "Retrieve test results..."

oc cp jws-test-image/jws-test-pod:/opt/artifacts/jws-5.x/ "${ARTIFACT_DIR}/jws_artifacts/jws-5/" --retries=5

for file in "${ARTIFACT_DIR}/jws_artifacts/jws-5/target/surefire-reports/"*.xml; do
    if [ -f "$file" ]; then
      cp "$file" "${ARTIFACT_DIR}/junit_jws_5_$(basename "$file" .xml).xml"
    fi
  done

result=`cat ${ARTIFACT_DIR}/junit_*.xml | sed 's/"//g'`
if [[ "$result" =~ "errors=0" ]] && [[ "$result" =~ "failures=0" ]]; then
  echo "Test done."; exit 0
else
  echo "Test failed."; exit 1
fi