#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Illegal number of parameters"
    exit 1
fi


TEAM=$1
OWNERS=$2
IFS=',' read -r -a OWNERS_ARRAY <<< "${OWNERS}"

OWNERS_PARAM=$(printf ",\"%s\"" "${OWNERS_ARRAY[@]}")
OWNERS_PARAM=$(echo [${OWNERS_PARAM:1}])

OUTPUT_DIR="clusters/hive/pools/$TEAM"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_FILE="${OUTPUT_DIR}/admins_${TEAM}-cluster-pool_rbac.yaml"
oc process -f clusters/hive/pools/_pool-admin-rbac_template.yaml -p TEAM=${TEAM} -p POOL_NAMESPACE=${TEAM}-cluster-pool -p "OWNERS=${OWNERS_PARAM}" -o yaml > "${OUTPUT_FILE}"
