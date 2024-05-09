#!/bin/bash

set -u

BUCKET_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}
EXTRA_ARGS=""

OPERATOR_IMAGE=$HYPERSHIFT_RELEASE_LATEST
if [[ $OCP_ARCH == "arm64" ]]; then
  OPERATOR_IMAGE="quay.io/hypershift/hypershift-operator:latest"
fi

if [ "${ENABLE_PRIVATE}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --private-platform=AWS \
  --aws-private-creds=/etc/hypershift-pool-aws-credentials/awsprivatecred \
  --aws-private-region=${REGION} \
  --external-dns-credentials=${CLUSTER_PROFILE_DIR}/.awscred \
  --external-dns-provider=aws \
  --external-dns-domain-filter=hypershift-ext.qe.devcluster.openshift.com "
fi

ho_version_info=$(hypershift -v)
ocp_version=$(echo "${ho_version_info}" | grep -oP 'Latest supported OCP: \K\d+\.\d+\.\d+')

# if latest supported version is 4.15.0 or above, add the cvo conditional update while installing HO
if [ -n "${ocp_version}" ]; then
    if [ "$(printf '%s\n' "4.15.0" "${ocp_version}" | sort -V | tail -n 1)" == "${ocp_version}" ]; then
        EXTRA_ARGS="${EXTRA_ARGS} --enable-cvo-management-cluster-metrics-access=true --enable-uwm-telemetry-remote-write=true "
    fi
fi

set -xe
bin/hypershift install --hypershift-image=${OPERATOR_IMAGE} \
--oidc-storage-provider-s3-credentials=${CLUSTER_PROFILE_DIR}/.awscred \
--oidc-storage-provider-s3-bucket-name=${BUCKET_NAME} \
--oidc-storage-provider-s3-region=${REGION} \
--wait-until-available \
${EXTRA_ARGS}
echo "" > ${SHARED_DIR}/.awsprivatecred