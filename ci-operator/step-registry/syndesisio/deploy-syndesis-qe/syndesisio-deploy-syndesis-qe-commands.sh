#!/bin/bash

set -u
set -e
set -o pipefail

CLUSTER_URL=$(cat "$SHARED_DIR"/console.url)
export CLUSTER_URL

ADMIN_PASSWORD=$(cat "$KUBEADMIN_PASSWORD_FILE")
export ADMIN_PASSWORD

export ADMIN_USERNAME="kubeadmin"
export UI_USERNAME="$ADMIN_USERNAME"
export UI_PASSWORD="$ADMIN_PASSWORD"
export FUSE_ONLINE_NAMESPACE="fuse-online"
export ONE_USER="true"
export PROFILE="rest,ui"
export TEST_PROPERTIES_FILE="test.properties"
export TEST_RUN_RESULTS_DIR="$ARTIFACT_DIR/test-run-results"
export CUCUMBER_DIR="tmp/seluser/syndesis-qe/ui-tests/target/cucumber"
export UI_TEST_BUILD_REPORTS_DIR="/tmp/seluser/syndesis-qe/ui-tests/build/reports/tests"
export UI_TEST_FAILSAFE_REPORTS_DIR="/tmp/seluser/syndesis-qe/ui-tests/target/failsafe-reports"
export TAGS='@smoke'
export MODULE='all'
export MODE='full'
export RETRIES='3'
export VNC='false'
export CATALOG_SOURCE='redhat-operators'
export CSV_CHANNEL='latest'
export MAVEN_OPTS=-Dmaven.repo.local=/tmp/seluser/.m2/repository

function retry() {
  local retries=0
  while [[ ${retries} -lt 18 ]]; do
    if "$@"; then
      return 0
    fi
    ((retries++))
    sleep 10
  done
  return 1
}

function check_pod_ready() {
  retry oc wait --for=condition=Ready -n openshift-marketplace pod -l olm.catalogSource=${CATALOG_SOURCE} --timeout=180s
}

mkdir -p "${TEST_RUN_RESULTS_DIR}"

check_pod_ready || exit 1
CSV_VERSION=$(oc get -n openshift-marketplace packagemanifests -l catalog==${CATALOG_SOURCE} -o=custom-columns=NAME:.metadata.name,CSVLATEST:".status.channels[?(@.name==\"${CSV_CHANNEL}\")].currentCSV" | awk "/fuse-online /{ print \$2 }")

oc login --insecure-skip-tls-verify=true -u "${UI_USERNAME}" -p "${UI_PASSWORD}" "${CLUSTER_URL}"
oc login --insecure-skip-tls-verify=true -u "${ADMIN_USERNAME}" -p "${ADMIN_PASSWORD}" "${CLUSTER_URL}"
oc project ${FUSE_ONLINE_NAMESPACE}

oc create --as system:admin user kubeadmin
oc create --as system:admin identity kube:admin
oc create --as system:admin useridentitymapping kube:admin kubeadmin
oc adm policy --as system:admin add-cluster-role-to-user cluster-admin kubeadmin

oc patch csv "$CSV_VERSION" -n $FUSE_ONLINE_NAMESPACE --type='json' -p='[{"op": "add", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-", "value": {"name": "TEST_SUPPORT", "value": "true"}}]'
oc delete pod -n $FUSE_ONLINE_NAMESPACE --all --wait=true

cat <<EOF | oc create -f -
apiVersion: syndesis.io/v1beta3
kind: Syndesis
metadata:
  name: app
spec:
  addons:
    jaeger:
      enabled: true
    todo:
      enabled: true
  components:
    scheduled: false
    server:
      features:
        integrationStateCheckInterval: 60
        integrationLimit: 1
  devSupport: false
EOF

cp /home/seluser /tmp -r
cd /tmp/seluser/syndesis-qe

cat <<EOF >"$TEST_PROPERTIES_FILE"
syndesis.config.ui.username=$UI_USERNAME
syndesis.config.ui.password=$UI_PASSWORD
syndesis.config.openshift.namespace=$FUSE_ONLINE_NAMESPACE
syndesis.config.openshift.namespace.lock=false
syndesis.config.ui.browser=chrome
syndesis.config.single.user=$ONE_USER
syndesis.config.openshift.url=$CLUSTER_URL
syndesis.config.admin.username=$ADMIN_USERNAME
syndesis.config.admin.password=$ADMIN_PASSWORD
syndesis.config.enableTestSupport=true
syndesis.config.install.operatorhub=true
syndesis.config.operatorhub.catalogsource=${CATALOG_SOURCE}
syndesis.config.operatorhub.csv.name=${CSV_VERSION}
syndesis.config.operatorhub.csv.channel=${CSV_CHANNEL}
syndesis.config.append.repository=false
EOF

Xvfb :99 -ac &

CURRENT_RETRIES=0
while [[ ${CURRENT_RETRIES} -lt ${RETRIES} ]]; do
  ./mvnw clean verify -fn -P "${PROFILE}" -Dtags="${TAGS}" -Dmaven.failsafe.debug="-Xdebug -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address=5005 -Xnoagent -Djava.compiler=NONE"
  if ! grep -R --exclude-dir docker "<failure message" .; then
    break
  fi
  ((CURRENT_RETRIES++))
done

cp -r $UI_TEST_BUILD_REPORTS_DIR "${ARTIFACT_DIR}/ui-test-build-reports"
cp -r $UI_TEST_FAILSAFE_REPORTS_DIR "${ARTIFACT_DIR}/ui-test-failsafe-reports"
cp "${CUCUMBER_DIR}/cucumber-junit.xml" "${ARTIFACT_DIR}/junit_ui-tests.xml"
cp "${CUCUMBER_DIR}/cucumber-report.json" "${ARTIFACT_DIR}/cucumber-report-ui-tests.json"