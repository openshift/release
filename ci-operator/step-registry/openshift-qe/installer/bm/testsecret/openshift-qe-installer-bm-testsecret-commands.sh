#!/bin/bash
set -eu

[[ if $(cat ${CLUSTER_PROFILE_DIR}/cloud_name) == "cloud19" ]]; then
    echo "cool!"
fi
