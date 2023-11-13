#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    >&2 echo "Illegal number of parameters"
    >&2 echo "$0 <team>"
    >&2 echo "E.g., $0 cvp"
    exit 1
fi


TEAM=$1

OUTPUT_DIR="clusters/hive/pools/$TEAM"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_FILE="${OUTPUT_DIR}/admins_${TEAM}-cluster-pool_rbac.yaml"
oc process --local -f clusters/hive/pools/_pool-admin-rbac_template.yaml -p TEAM=${TEAM} -p POOL_NAMESPACE=${TEAM}-cluster-pool -o yaml > "${OUTPUT_FILE}"
