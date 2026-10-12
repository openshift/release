#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

# Extract clusters archive from SHARED_DIR
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data

RUN_COMMAND="poetry run pytest tests \
            -o log_cli=true \
            --junit-xml=${ARTIFACT_DIR}/xunit_results.xml \
            --pytest-log-file=${ARTIFACT_DIR}/pytest-tests.log \
            -m ${TEST_MARKER} \
            --data-collector=data-collector-openshift-ci.yaml "

if [[ -n "${CLUSTER1_KUBECONFIG_PATH}" ]]; then
  KUBECONFIG_COMMAND="--kubeconfig-file-paths=${CLUSTER1_KUBECONFIG_PATH}"
  if [[ -n "${CLUSTER2_KUBECONFIG_PATH}" ]]; then
    KUBECONFIG_COMMAND+=",${CLUSTER2_KUBECONFIG_PATH}"
    if [[ -n "${CLUSTER3_KUBECONFIG_PATH}" ]]; then
      KUBECONFIG_COMMAND+=",${CLUSTER3_KUBECONFIG_PATH} "
    fi
    RUN_COMMAND+=" ${KUBECONFIG_COMMAND} "
  fi
else
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi


echo "$RUN_COMMAND"

${RUN_COMMAND}
