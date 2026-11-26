#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Enabling the image-registry default route..."
oc patch configs.imageregistry.operator.openshift.io cluster \
    --type=merge \
    -p '{"spec":{"defaultRoute":true}}'

echo "Waiting for the public registry hostname to become available..."
TIMEOUT=600
ELAPSED=0
until LAST_LOOKUP_OUTPUT=$(oc registry info --public 2>&1) && [[ -n "${LAST_LOOKUP_OUTPUT//[[:space:]]/}" ]]; do
    if (( ELAPSED >= TIMEOUT )); then
        echo "ERROR: timed out after ${TIMEOUT}s waiting for public registry hostname"
        printf '%s\n' "${LAST_LOOKUP_OUTPUT}"
        exit 1
    fi
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
done

printf 'Public registry endpoint: %s\n' "${LAST_LOOKUP_OUTPUT}"
