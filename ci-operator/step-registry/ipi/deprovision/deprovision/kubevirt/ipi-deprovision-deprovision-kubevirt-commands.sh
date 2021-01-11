#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

cp -ar "${SHARED_DIR}" ${HOME}/installer
KUBECONFIG=${HOME}/secret-kube/kubeconfig-infra-cluster openshift-install --dir ${HOME}/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

cp ${HOME}/installer/.openshift_install.log "${ARTIFACT_DIR}"

exit "$ret"
