#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


CONFIG="${SHARED_DIR}/install-config.yaml"

cat "${SHARED_DIR}/customer_vpc_subnets.yaml"

yq-go m -x -i "${CONFIG}" "${SHARED_DIR}/customer_vpc_subnets.yaml"


