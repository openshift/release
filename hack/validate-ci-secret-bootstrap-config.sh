#!/usr/bin/env bash
set -euo pipefail

LIST_FILE="$(mktemp)"

trap 'rm -f ${LIST_FILE}' EXIT

SCRIPT_DIR=$(dirname $0)

CONFIG_PATH=$(dirname ${SCRIPT_DIR})/core-services/ci-secret-bootstrap/_config.yaml

yq -y '[.secret_configs[] | select((.to | any(.type=="kubernetes.io/dockerconfigjson")) and (.from | has(".dockerconfigjson") | not))] ' "${CONFIG_PATH}" > "${LIST_FILE}"

LENGTH=$(yq '. | length' ${LIST_FILE})

if (( ${LENGTH} > 0 )); then
    echo 'Those secrets with kubernetes.io/dockerconfigjson type have no key named .dockerconfigjson'
    cat ${LIST_FILE}
    exit 1
fi
