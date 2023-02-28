#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${OPENSHIFT_VERSION:-}" ]]; then
    echo "ERROR: Expect a defined OPENSHIFT_VERSION"
    exit 1
fi

/usr/bin/openshift-ci.sh create openshift-4 "${OPENSHIFT_VERSION}"
