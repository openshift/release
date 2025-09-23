#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../../lib"

: "${HOST_PROVIDER:?HOST_PROVIDER must be defined (e.g. ofcir, vsphere, nutanix)}"

provider_script="${LIB_DIR}/host-providers/assisted-common-lib-host-providers-${HOST_PROVIDER}-commands.sh"
if [[ ! -f "$provider_script" ]]; then
    echo "Unknown host provider: ${HOST_PROVIDER}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$provider_script"

gather_fn="host_provider_${HOST_PROVIDER}::gather"
if ! declare -F "$gather_fn" >/dev/null; then
    echo "Host provider ${HOST_PROVIDER} does not implement gather(), skipping" >&2
    exit 0
fi

if ! "$gather_fn"; then
    echo "Host provider ${HOST_PROVIDER} failed to gather artifacts" >&2
    exit 1
fi

echo "Host artifact gathering completed via provider ${HOST_PROVIDER}" >&2