#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# shellcheck disable=SC1091
source "$LEASE_PROXY_CLIENT_SH"
source ci-operator/step-registry/aro-hcp/lease/common/aro-hcp-lease-common-commands.sh

aro_hcp_lease::release_all
