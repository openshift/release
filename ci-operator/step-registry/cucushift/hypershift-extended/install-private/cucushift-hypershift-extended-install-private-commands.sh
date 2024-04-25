#!/bin/bash

set -u

BUCKET_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

RUN_COMMAND="bin/hypershift install --hypershift-image=${HYPERSHIFT_RELEASE_LATEST} \
--oidc-storage-provider-s3-credentials=${CLUSTER_PROFILE_DIR}/.awscred \
--oidc-storage-provider-s3-bucket-name=${BUCKET_NAME} \
--oidc-storage-provider-s3-region=${HYPERSHIFT_AWS_REGION} \
--private-platform=AWS \
--aws-private-creds=/etc/hypershift-pool-aws-credentials/awsprivatecred \
--aws-private-region=${HYPERSHIFT_AWS_REGION} \
--external-dns-credentials=${CLUSTER_PROFILE_DIR}/.awscred \
--external-dns-provider=aws \
--external-dns-domain-filter=hypershift-ext.qe.devcluster.openshift.com \
--wait-until-available "

ho_version_info=$(hypershift -v)
ocp_version=$(echo "${ho_version_info}" | grep -oP 'Latest supported OCP: \K\d+\.\d+\.\d+')

# if latest supported version is 4.15.0 or above, add the cvo conditional update while installing HO
if [ -n "${ocp_version}" ]; then
    if [ "$(printf '%s\n' "4.15.0" "${ocp_version}" | sort -V | tail -n 1)" == "${ocp_version}" ]; then
        RUN_COMMAND+=" --enable-cvo-management-cluster-metrics-access=true --enable-uwm-telemetry-remote-write=true "
    fi
fi

set -xe
${RUN_COMMAND}
echo "" > ${SHARED_DIR}/.awsprivatecred