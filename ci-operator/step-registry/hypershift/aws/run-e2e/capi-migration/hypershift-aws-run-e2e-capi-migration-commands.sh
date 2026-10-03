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

AWS_OBJECT_PARAMS=""
if check_e2e_flag 'e2e.aws-oidc-s3-bucket-name'; then
  AWS_OBJECT_PARAMS="--e2e.aws-oidc-s3-bucket-name=hypershift-ci-oidc --e2e.aws-kms-key-alias=alias/hypershift-ci"
fi

ADDITIONAL_PULL_SECRET_PARAMS=""
if check_e2e_flag 'e2e.additional-pull-secret-file' && [[ -f /etc/hypershift-additional-pull-secret/.dockerconfigjson ]]; then
  ADDITIONAL_PULL_SECRET_PARAMS="--e2e.additional-pull-secret-file=/etc/hypershift-additional-pull-secret/.dockerconfigjson"
fi

export EVENTUALLY_VERBOSE="false"

hack/ci-test-e2e.sh -test.v \
  -test.run='^TestCAPIStorageVersionMigration$' \
  -test.parallel=1 \
  --e2e.aws-credentials-file=/etc/hypershift-pool-aws-credentials/credentials \
  --e2e.aws-zones=us-east-1a,us-east-1b,us-east-1c \
  ${AWS_OBJECT_PARAMS:-} \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.base-domain=ci.hypershift.devcluster.openshift.com \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" \
  --e2e.additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)" \
  --e2e.aws-endpoint-access=PublicAndPrivate \
  --e2e.external-dns-domain=service.ci.hypershift.devcluster.openshift.com \
  --e2e.private-platform=AWS \
  --e2e.ho-enable-ci-debug-output=true \
  --e2e.hypershift-operator-latest-image=${CI_HYPERSHIFT_OPERATOR} \
  ${CAPI_MIGRATION_PARAM} \
  ${ADDITIONAL_PULL_SECRET_PARAMS:-} &
wait $!
