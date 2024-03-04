#!/bin/bash

set -eux

EXTRA_ARGS=""

OPERATOR_IMAGE=$HYPERSHIFT_RELEASE_LATEST
if [[ $OCP_ARCH == "arm64" ]]; then
  OPERATOR_IMAGE="quay.io/hypershift/hypershift-operator:latest-arm64"
fi

if [ "${ENABLE_HYPERSHIFT_OPERATOR_DEFAULTING_WEBHOOK}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --enable-defaulting-webhook=true"
fi

if [ "${ENABLE_HYPERSHIFT_OPERATOR_VALIDATING_WEBHOOK}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --enable-validating-webhook=true"
fi

if [ "${ENABLE_HYPERSHIFT_CERT_ROTATION_SCALE}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --cert-rotation-scale=20m"
fi

bin/hypershift install --hypershift-image="${OPERATOR_IMAGE}" \
--platform-monitoring=All \
--enable-ci-debug-output \
--wait-until-available \
${EXTRA_ARGS}