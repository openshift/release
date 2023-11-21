#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

sleep 2h

# Login to the ACM hub cluster as kube:admin
KUBEADMIN_PASSWORD=$(cat ${SHARED_DIR}/${HUB_CLUSTER_NAME}/kubeadmin-password)
oc login --username=kubeadmin --password=${KUBEADMIN_PASSWORD}

# Run ACM Observability tests
KUBEADMIN_TOKEN=$(oc whoami -t)
export KUBEADMIN_TOKEN

RUN_COMMAND="poetry run pytest tests \
            -o log_cli=true \
            --junit-xml=${ARTIFACT_DIR}/xunit_results.xml \
            --pytest-log-file=${ARTIFACT_DIR}/pytest-tests.log \
            -m acm-observability \
            --data-collector=data-collector-openshift-ci.yaml "

KUBECONFIG_COMMAND="--kubeconfig-file-paths="${HUB_CLUSTER_KUBECONFIG_PATH}"

RUN_COMMAND+=" ${KUBECONFIG_COMMAND} "

echo "$RUN_COMMAND"

${RUN_COMMAND}