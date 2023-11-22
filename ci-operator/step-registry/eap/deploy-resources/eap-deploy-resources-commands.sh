#!/bin/bash

set +u
set -o errexit
set -o pipefail

sleep 2h

function create_eap_configmaps()
{
  CREDENTIALS=$(cat /tmp/secrets/eap/credentials)
  CONSOLE_URL=$(cat "$SHARED_DIR"/console.url)
  API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
  KUBEADMIN_PWD=$(cat "$SHARED_DIR"/kubeadmin-password)

  export CREDENTIALS
  export API_URL
  export KUBEADMIN_PWD

  cat << EOF > /tmp/test.properties
openshift.namespace=tnb-tests
openshift.namespace.delete=false
test.credentials.file=/deployments/tnb-tests/credentials.yaml
test.maven.repository=https://maven.repository.redhat.com/ga/
dballocator.url=http://dballocator.mw.lab.eng.bos.redhat.com:8080
dballocator.requestee=software.tnb.db.dballocator.service
dballocator.expire=6
dballocator.erase=true
tnb.user=tnb-tests
camel.springboot.examples.repo=https://github.com/jboss-fuse/camel-spring-boot-examples.git
camel.springboot.examples.branch=camel-spring-boot-examples-${CSB_RELEASE}.redhat-00001
EOF

oc delete configmap test-properties -n "${1}" || true
oc create configmap test-properties -n "${1}" --from-file=/tmp/test.properties
}