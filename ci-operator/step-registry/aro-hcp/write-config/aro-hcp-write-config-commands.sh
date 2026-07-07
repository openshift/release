#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Each ci-operator step runs in its own pod; git state does not carry over.
aro_hcp_git_checkout() {
  local ref="$1"
  if [[ -z "${ref}" ]]; then
    echo "ERROR: git checkout ref must not be empty"
    return 1
  fi

  echo "Checking out ${ref}"
  git fetch --tags origin 2>/dev/null || true
  git fetch --unshallow origin 2>/dev/null || true
  git fetch origin "${ref}" 2>/dev/null || true
  if ! git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
    echo "ERROR: ref ${ref} is not available locally after fetch"
    return 1
  fi
  if ! git checkout "${ref}"; then
    echo "ERROR: failed to checkout ${ref}"
    return 1
  fi
  git rev-parse HEAD
}

if [[ -n "${PROVISION_GIT_REF:-}" ]]; then
  aro_hcp_git_checkout "${PROVISION_GIT_REF}"
fi

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
    export LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi

env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
fi

if [[ -n "${SELECTED_LOCATION:-}" ]]; then
    export LOCATION="${SELECTED_LOCATION}"
fi

: "${LOCATION:?LOCATION must be set directly, via Gangway override, or by SELECTED_LOCATION in the runtime slot export file}"

export AZURE_TOKEN_CREDENTIALS=prod

# NOTE: this config will be only partially accurate on public envs
make -C config render-partial-config \
  ARO_HCP_CLOUD="${ARO_HCP_CLOUD}" \
  ARO_HCP_DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}" \
  LOCATION="${LOCATION}" \
  STAMP=1 \
  CONFIG_OUTPUT="${SHARED_DIR}/config.yaml"

cp "${SHARED_DIR}/config.yaml" "${ARTIFACT_DIR}/config.yaml"

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${SHARED_DIR}/write-config-timestamp-rfc3339"
