#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/must-gather-image.sh"
then
    echo "WARNING, must-gather-image.sh already exists"
else
    cat >"${SHARED_DIR}/must-gather-image.sh" <<EOF
export MUST_GATHER_IMAGE=--image="$OADP_MUST_GATHER_IMAGE"
EOF
fi

cat "${SHARED_DIR}/must-gather-image.sh"

