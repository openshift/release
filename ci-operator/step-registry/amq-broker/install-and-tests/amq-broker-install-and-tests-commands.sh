#!/bin/bash

set +u
set -o errexit
set -o pipefail

echo "Copy KUBECONFIG to /app/.kube/config"
cp $KUBECONFIG /app/.kube/config

echo "Execute tests"
make operator_test_smoke