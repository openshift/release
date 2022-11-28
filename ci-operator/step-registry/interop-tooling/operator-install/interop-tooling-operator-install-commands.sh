#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

echo "This is the interop-tooling-operator-install-command.sh space running"

cat /etc/os-release

cat interop-tests/interop_tests/operator_install/operator_install.py

export KUBECONFIG=${SHARED_DIR}/kubeconfig

python interop-tests/interop_tests/operator_install/operator_install.py advanced-cluster-management open-cluster-management release-2.6 redhat-operators openshift-marketplace
