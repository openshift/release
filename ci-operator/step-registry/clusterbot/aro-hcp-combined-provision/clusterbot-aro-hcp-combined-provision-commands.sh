#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Require all ARO-HCP PR images before provisioning the combined environment.
for image in BACKEND_IMAGE FRONTEND_IMAGE ADMIN_API_IMAGE SESSIONGATE_IMAGE \
    HCP_RECOVERY_IMAGE FLEET_IMAGE MGMT_AGENT_IMAGE KUBE_APPLIER_IMAGE EXPORTER_IMAGE; do
    if [[ -z "${!image:-}" ]]; then
        echo "ERROR: ${image} must be built from the ARO-HCP PR" >&2
        exit 1
    fi
done

if [[ ! -s "${SHARED_DIR}/hypershift-image-overrides.yaml" ]]; then
    echo "ERROR: HyperShift PR image overrides are missing" >&2
    exit 1
fi

env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
fi
export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"
: "${LOCATION:?LOCATION must be provided by the runtime slot}"
if [[ "${VAULT_SECRET_PROFILE}" != "dev" ]]; then
    echo "ERROR: clusterbot ARO HCP combined provisioning only supports VAULT_SECRET_PROFILE=dev" >&2
    exit 1
fi
export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-dev"

# ARO-HCP owns image and lease overrides, including the HyperShift merge.
exec hack/ci/provision-environment.sh
