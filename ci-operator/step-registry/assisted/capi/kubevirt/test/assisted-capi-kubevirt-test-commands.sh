#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ -z "${KUBECONFIG}" || ! -r "${KUBECONFIG}" ]]; then
  echo "ERROR: The workflow did not provide a readable management-cluster kubeconfig"
  exit 1
fi

if [[ "${OPENSHIFT_VERSION:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  OPENSHIFT_VERSION="$(python3 hack/resolve_release.py version --version "${OPENSHIFT_VERSION}")"
  export OPENSHIFT_VERSION
fi

export GOCACHE=/tmp
export HOME=/tmp

make "${TEST_TARGET}"
