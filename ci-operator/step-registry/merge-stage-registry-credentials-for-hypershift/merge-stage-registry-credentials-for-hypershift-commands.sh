#!/bin/bash
#
# Merge registry.stage.redhat.io credentials into the pull secret used when
# creating a HyperShift HostedCluster. Run before hypershift-hostedcluster-create;
# that step merges pull-secret-build-farm.json with CI credentials and passes
# the result to hypershift create cluster --pull-secret.

set -euo pipefail

STAGE_REGISTRY_PATH="/var/run/vault/mirror-registry/registry_stage.json"
PULL_SECRET_BUILD_FARM="${SHARED_DIR}/pull-secret-build-farm.json"
PULL_SECRET_WORKDIR="/tmp/merge-stage-registry-credentials-for-hypershift"

if [[ ! -f "${STAGE_REGISTRY_PATH}" ]]; then
    echo "Stage registry credentials not found at ${STAGE_REGISTRY_PATH}"
    exit 1
fi

mkdir -p "${PULL_SECRET_WORKDIR}"

if [[ -f "${PULL_SECRET_BUILD_FARM}" ]]; then
    cp "${PULL_SECRET_BUILD_FARM}" "${PULL_SECRET_WORKDIR}/base.json"
else
    echo '{"auths":{}}' > "${PULL_SECRET_WORKDIR}/base.json"
fi

if ! jq -e . "${PULL_SECRET_WORKDIR}/base.json" >/dev/null; then
    echo "Existing ${PULL_SECRET_BUILD_FARM} is not valid JSON"
    exit 1
fi

echo "Merging registry.stage.redhat.io credentials into ${PULL_SECRET_BUILD_FARM}..."
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
# Disable tracing while handling registry credentials.
set +x
stage_auth_user=$(jq -er '.user | strings | select(length > 0)' "${STAGE_REGISTRY_PATH}")
stage_auth_password=$(jq -er '.password | strings | select(length > 0)' "${STAGE_REGISTRY_PATH}")
stage_registry_auth=$(printf '%s:%s' "${stage_auth_user}" "${stage_auth_password}" | base64 -w 0)

jq --argjson stage "{\"registry.stage.redhat.io\": {\"auth\": \"${stage_registry_auth}\"}}" \
   '.auths |= . + $stage' "${PULL_SECRET_WORKDIR}/base.json" > "${PULL_SECRET_WORKDIR}/merged.json"
$WAS_TRACING && set -x

if ! jq -e '.auths["registry.stage.redhat.io"].auth' "${PULL_SECRET_WORKDIR}/merged.json" >/dev/null; then
    echo "Failed to merge registry.stage.redhat.io credentials into pull secret"
    exit 1
fi

cp "${PULL_SECRET_WORKDIR}/merged.json" "${PULL_SECRET_BUILD_FARM}"
echo "Stage registry credentials merged into ${PULL_SECRET_BUILD_FARM}"
