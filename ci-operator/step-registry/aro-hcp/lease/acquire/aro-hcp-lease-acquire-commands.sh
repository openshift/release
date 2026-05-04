#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# shellcheck disable=SC1091
source "$LEASE_PROXY_CLIENT_SH"
source ci-operator/step-registry/aro-hcp/lease/common/aro-hcp-lease-common-commands.sh

function on_exit() {
    local exit_code="$1"
    if [[ "$exit_code" -ne 0 ]]; then
        aro_hcp_lease::release_all || true
    fi
}

trap 'on_exit $?' EXIT

aro_hcp_lease::prepare_state

case "${ARO_HCP_DEPLOY_ENV}" in
    prow|ci01)
        aro_hcp_lease::acquire_role "env-quota" "aro-hcp-dev-quota-slice" "1"
        aro_hcp_lease::acquire_role "msi-containers" "aro-hcp-test-msi-containers-dev" "20"
        aro_hcp_lease::acquire_role "msi-mock-sp" "aro-hcp-msi-mock-cs-sp-dev" "1"
        ;;
    int)
        aro_hcp_lease::acquire_role "env-quota" "aro-hcp-int-quota-slice" "1"
        aro_hcp_lease::acquire_role "msi-containers" "aro-hcp-test-msi-containers-int" "20"
        ;;
    stg)
        aro_hcp_lease::acquire_role "env-quota" "aro-hcp-stg-quota-slice" "1"
        aro_hcp_lease::acquire_role "msi-containers" "aro-hcp-test-msi-containers-stg" "30"
        ;;
    prod)
        aro_hcp_lease::acquire_role "env-quota" "aro-hcp-prod-quota-slice" "1"
        aro_hcp_lease::acquire_role "msi-containers" "aro-hcp-test-msi-containers-prod" "15"
        ;;
    *)
        printf 'Unsupported ARO_HCP_DEPLOY_ENV: %s\n' "${ARO_HCP_DEPLOY_ENV}" >&2
        exit 1
        ;;
esac

aro_hcp_lease::write_env_exports
printf 'Prepared ARO HCP runtime lease exports in %s\n' "$(aro_hcp_lease::env_file)"

trap - EXIT
