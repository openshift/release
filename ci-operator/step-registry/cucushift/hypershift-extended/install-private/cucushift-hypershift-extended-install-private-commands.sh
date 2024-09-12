#!/bin/bash

set -u

# Get HO image and Hypershift CLI
HCP_CLI="bin/hypershift"
OPERATOR_IMAGE=$HYPERSHIFT_RELEASE_LATEST
if [[ $HO_MULTI == "true" ]]; then
  OPERATOR_IMAGE="quay.io/acm-d/rhtap-hypershift-operator:latest"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  mkdir /tmp/hs-cli
  oc image extract quay.io/acm-d/rhtap-hypershift-operator:latest --path /usr/bin/hypershift:/tmp/hs-cli --registry-config=/tmp/.dockerconfigjson --filter-by-os="linux/amd64"
  chmod +x /tmp/hs-cli/hypershift
  HCP_CLI="/tmp/hs-cli/hypershift"
fi

# Build up the hypershift install command
COMMAND=(
    "${HCP_CLI}" install
    --hypershift-image="${OPERATOR_IMAGE}"
    --wait-until-available
)

if [[ -n "$HYPERSHIFT_MANAGED_SERVICE" ]]; then
    COMMAND+=(--managed-service="$HYPERSHIFT_MANAGED_SERVICE")
fi

if [[ "$HYPERSHIFT_ENABLE_CONVERSION_WEBHOOK" == "true" ]]; then
    COMMAND+=(--enable-conversion-webhook="true")
else
    COMMAND+=(--enable-conversion-webhook="false")
fi

if [[ "$HYPERSHIFT_OPERATOR_PULL_SECRET" == "true" ]]; then
    PULL_SECRET_PATH="${CLUSTER_PROFILE_DIR}/pull-secret"
    if [[ -f "${SHARED_DIR}/hypershift-pull-secret" ]]; then
        PULL_SECRET_PATH="${SHARED_DIR}/hypershift-pull-secret"
    fi
    COMMAND+=(--pull-secret="$PULL_SECRET_PATH")
fi

case "${CLUSTER_TYPE,,}" in
*aws*)
    BUCKET_NAME="$(echo -n "$PROW_JOB_ID"|sha256sum|cut -c-20)"
    REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

    COMMAND+=(
        --oidc-storage-provider-s3-credentials="${CLUSTER_PROFILE_DIR}/.awscred"
        --oidc-storage-provider-s3-bucket-name="${BUCKET_NAME}"
        --oidc-storage-provider-s3-region="${REGION}"
    )

    if [[ -n "$HYPERSHIFT_EXTERNAL_DNS_DOMAIN" ]]; then
        COMMAND+=(
            --external-dns-credentials="${CLUSTER_PROFILE_DIR}/.awscred"
            --external-dns-provider=aws
            --external-dns-domain-filter="$HYPERSHIFT_EXTERNAL_DNS_DOMAIN"
        )
    fi

    if [[ "${ENABLE_PRIVATE}" = "true" ]]; then
        COMMAND+=(
            --private-platform=AWS
            --aws-private-creds=/etc/hypershift-pool-aws-credentials/awsprivatecred
            --aws-private-region="${REGION}"
        )
    fi

    # If latest supported version is 4.15.0 or above, add the cvo conditional update while installing HO
    ho_version_info=$("${HCP_CLI}" -v)
    ocp_version=$(echo "${ho_version_info}" | grep -oP 'Latest supported OCP: \K\d+\.\d+\.\d+')
    if [ -n "${ocp_version}" ]; then
        if [ "$(printf '%s\n' "4.15.0" "${ocp_version}" | sort -V | tail -n 1)" == "${ocp_version}" ]; then
            COMMAND+=(--enable-cvo-management-cluster-metrics-access=true --enable-uwm-telemetry-remote-write=true)
        fi
    fi
    ;;
*azure*)
    if [[ -n "$HYPERSHIFT_EXTERNAL_DNS_DOMAIN" ]]; then
        COMMAND+=(
            --external-dns-credentials=/etc/hypershift-ext-dns-app-azure/credentials
            --external-dns-provider=azure
            --external-dns-domain-filter="$HYPERSHIFT_EXTERNAL_DNS_DOMAIN"
        )
    fi
    ;;
*)
    echo "Unsupported platform ${CLUSTER_TYPE}" >&2
    exit 1
    ;;
esac

# Hypershift install
set -ex
eval "${COMMAND[*]}"
