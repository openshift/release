#!/bin/bash

set -eux

RUN_STEP="${RUN_EXTERNAL_INFRA_TEST:-true}"

if [ "${RUN_STEP}" != "true" ]
then
  echo "Hypershift installation step has been skipped."
  exit 0
fi

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig

OPERATOR_IMAGE=${HYPERSHIFT_RELEASE_LATEST}

bin/hypershift install --hypershift-image="${OPERATOR_IMAGE}" \
--platform-monitoring=All \
--enable-ci-debug-output \
--wait-until-available
