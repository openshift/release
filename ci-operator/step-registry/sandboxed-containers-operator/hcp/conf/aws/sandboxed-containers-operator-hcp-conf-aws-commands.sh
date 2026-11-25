#!/bin/bash

set -euo pipefail
# No -x: this step handles container pull secrets; command tracing would leak
# them into the CI log.

echo "=========================================="
echo "OSC HCP :: conf aws (cloud-specific configuration)"
echo "=========================================="

# ---------------------------------------------------------------- inputs
REGION="${AWS_REGION:-${LEASED_RESOURCE:-}}"
if [[ -z "${REGION}" ]]; then
    echo "ERROR: AWS region not set (AWS_REGION or LEASED_RESOURCE)"
    exit 1
fi

# Base domain: env override, else the cluster profile's baseDomain file
# (same resolution as ipi-conf-aws).
if [[ -z "${BASE_DOMAIN:-}" ]]; then
    if [[ -s "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
        BASE_DOMAIN="$(< "${CLUSTER_PROFILE_DIR}/baseDomain")"
    else
        echo "ERROR: BASE_DOMAIN not set and ${CLUSTER_PROFILE_DIR}/baseDomain missing"
        exit 1
    fi
fi

[[ -n "${RELEASE_IMAGE_LATEST:-}" ]] || { echo "ERROR: RELEASE_IMAGE_LATEST is not set"; exit 1; }

PULL_SECRET="${CLUSTER_PROFILE_DIR}/pull-secret"
[[ -f "${PULL_SECRET}" ]] || { echo "ERROR: pull secret not found at ${PULL_SECRET}"; exit 1; }

HCP_DIR="${SHARED_DIR}/hcp"
BINDIR="${HCP_DIR}/bin"
mkdir -p "${BINDIR}"

# ---------------------------------------------------------------- tools
for tool in oc aws jq openshift-install; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: ${tool} not found in the step image"; exit 1; }
done

# ccoctl: extracted from the cloud-credential-operator image in the payload.
cco_image="$(oc adm release info --image-for='cloud-credential-operator' "${RELEASE_IMAGE_LATEST}" -a "${PULL_SECRET}")"
oc image extract "${cco_image}" -a "${PULL_SECRET}" --path="/usr/bin/ccoctl:${BINDIR}" --confirm
chmod +x "${BINDIR}/ccoctl"

# hypershift CLI: extracted from the hypershift-operator pipeline image.
oc image extract "${HYPERSHIFT_RELEASE_LATEST}" --path="/usr/bin/hypershift:${BINDIR}" \
    --registry-config=/etc/ci-pull-credentials/.dockerconfigjson \
    --filter-by-os=linux/amd64 --confirm
chmod +x "${BINDIR}/hypershift"

# ---------------------------------------------------------------- env
# Written before any provisioning runs so the deprovision step can source it
# even when provision fails halfway. The hypershift-cluster-setup script's
# --prow mode consumes this OSC CI vocabulary as defaults for its HCP_*
# variables (explicitly-set HCP_* still wins on the laptop).
cat > "${HCP_DIR}/env.sh" <<ENV_EOF
export PATH="${BINDIR}:\${PATH}"
export HCP_CLOUD=aws
export AWS_REGION="${REGION}"
export BASE_DOMAIN="${BASE_DOMAIN}"
export COMPUTE_NODE_REPLICAS="${COMPUTE_NODE_REPLICAS:-2}"
export COMPUTE_NODE_TYPE="${COMPUTE_NODE_TYPE:-m8i.large}"
export MGMT_COMPUTE_NODE_TYPE="${MGMT_COMPUTE_NODE_TYPE:-m5.xlarge}"
export ENABLE_NESTED_VIRT="${ENABLE_NESTED_VIRT:-yes}"
export MGMT_INSTALL_MAX_RETRIES="${MGMT_INSTALL_MAX_RETRIES:-2}"
export IMAGE_CONTENT_SOURCES="${IMAGE_CONTENT_SOURCES:-}"
export HCP_RELEASE_IMAGE="${RELEASE_IMAGE_LATEST}"
export HCP_MGMT_RELEASE_IMAGE="${RELEASE_IMAGE_LATEST}"
ENV_EOF

echo "HCP AWS configuration written to ${HCP_DIR}/env.sh (region: ${REGION})"
