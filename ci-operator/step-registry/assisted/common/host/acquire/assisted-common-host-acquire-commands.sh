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

acquire_fn="host_provider_${HOST_PROVIDER}::acquire"
if ! declare -F "$acquire_fn" >/dev/null; then
    echo "Host provider ${HOST_PROVIDER} does not implement acquire()" >&2
    exit 1
fi

if ! "$acquire_fn"; then
    echo "Host provider ${HOST_PROVIDER} failed to acquire host" >&2
    exit 1
fi

echo "Host acquisition completed via provider ${HOST_PROVIDER}" >&2

