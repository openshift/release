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

OCP_VERSION="$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -a "${CLUSTER_PROFILE_DIR}/pull-secret" | grep -oP '(?<=^  Version:  ).*$' | grep -oE '^[0-9]+\.[0-9]+')"
EXTRA_ARGS="--additional-operator-env-vars=IMAGE_KUBEVIRT_CAPI_PROVIDER=registry.ci.openshift.org/ocp/${OCP_VERSION}:cluster-api-provider-kubevirt"

bin/hypershift install --hypershift-image="${OPERATOR_IMAGE}" \
--platform-monitoring=All \
--enable-ci-debug-output \
--wait-until-available \
--enable-validating-webhook=true \
${EXTRA_ARGS}
