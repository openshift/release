#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

export KUBECONFIG=${SHARED_DIR}/kubeconfig

poetry run python3 app/cli.py operator \
    --kubeconfig "${KUBECONFIG}" \
    --name "${OPERATOR_NAME}" \
    --namespace "${OPERATOR_NAMESPACE}" \
    --timeout "${TIMEOUT}" \
    install
