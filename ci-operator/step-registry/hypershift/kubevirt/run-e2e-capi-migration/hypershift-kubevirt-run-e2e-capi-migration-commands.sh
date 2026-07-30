#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function cleanup() {
  for child in $( jobs -p ); do
    kill "${child}"
  done
  wait
}
trap cleanup EXIT

check_e2e_flag() {
  grep -Fq -- "$1" <<<"$( bin/test-e2e -h 2>&1 )"
  return $?
}

CAPI_MIGRATION_PARAM=""
if check_e2e_flag "capi-migration.run-tests" ; then
  CAPI_MIGRATION_PARAM="--capi-migration.run-tests"
fi

STORAGE_CLASS_FLAG=""
if [[ -n ${ETCD_STORAGE_CLASS:-} ]]; then
  STORAGE_CLASS_FLAG="--e2e.etcd-storage-class=${ETCD_STORAGE_CLASS}"
fi

ADDITIONAL_PULL_SECRET_PARAMS=""
if check_e2e_flag 'e2e.additional-pull-secret-file' && [[ -f /etc/hypershift-additional-pull-secret/.dockerconfigjson ]]; then
  ADDITIONAL_PULL_SECRET_PARAMS="--e2e.additional-pull-secret-file=/etc/hypershift-additional-pull-secret/.dockerconfigjson"
fi

export EVENTUALLY_VERBOSE="false"

hack/ci-test-e2e.sh -test.v \
  -test.run='^TestCAPIStorageVersionMigration$' \
  -test.parallel=1 \
  --e2e.platform="KubeVirt" \
  --e2e.kubevirt-node-memory="10Gi" \
  --e2e.kubevirt-node-cores="4" \
  --e2e.node-pool-replicas=2 \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.ho-enable-ci-debug-output=true \
  --e2e.hypershift-operator-latest-image=${CI_HYPERSHIFT_OPERATOR} \
  ${STORAGE_CLASS_FLAG} \
  ${CAPI_MIGRATION_PARAM} \
  ${ADDITIONAL_PULL_SECRET_PARAMS:-} &
wait $!
