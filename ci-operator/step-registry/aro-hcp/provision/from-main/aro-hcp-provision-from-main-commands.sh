#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
fi

export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"
: "${LOCATION:?LOCATION must be provided by SELECTED_LOCATION or the legacy runtime slot export file}"

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Optional PR-tunable baseline pin. Fetches the ref and forces the
# PULL_BASE_SHA path in ARO-HCP's provision-from-main.sh (which otherwise
# uses the Prow merge base).
if [[ -n "${ARO_HCP_BASELINE_GIT_REF:-}" ]]; then
  echo "ARO_HCP_BASELINE_GIT_REF=${ARO_HCP_BASELINE_GIT_REF}: fetching baseline override ..."
  git fetch https://github.com/Azure/ARO-HCP.git "${ARO_HCP_BASELINE_GIT_REF}"
  export PULL_BASE_SHA
  PULL_BASE_SHA=$(git rev-parse FETCH_HEAD)
  echo "Resolved baseline override to ${PULL_BASE_SHA}"
fi

exec hack/ci/provision-from-main.sh
