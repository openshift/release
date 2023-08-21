#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

# Set the ocp env variables and execute oc login
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
OCP_CRED_USR="kubeadmin"
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true

# Execute tests
sh run.sh

# Collect test reports into $ARTIFACT_DIR
echo "Copying results and xmls to ${ARTIFACT_DIR}"
for PROJECT in ${PROJECTS//","/" "}; do
  for FILE in ./$PROJECT/target/failsafe-reports/TEST-*.xml; do
    FILENAME=$(basename $FILE)
    TARGET=${ARTIFACT_DIR}/junit_${FILENAME}
    echo "Collecting ${TARGET}"
    cp $FILE $TARGET
  done
done
