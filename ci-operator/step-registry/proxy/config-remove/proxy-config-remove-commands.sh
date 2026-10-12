#!/bin/bash

set -euxo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
    rm "${SHARED_DIR}/proxy-conf.sh"
fi

if [ -f "${SHARED_DIR}/unset-proxy.sh" ]; then
    rm "${SHARED_DIR}/unset-proxy.sh"
fi
