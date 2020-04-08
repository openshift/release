#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

WORKDIR="$(mktemp -d)"
readonly WORKDIR

CLUSTER_NAME="build01"
readonly CLUSTER_NAME

INPUT_YAML="${WORKDIR}/worker-user-data_secret.yaml"
readonly INPUT_YAML

OUTPUT_YAML="${WORKDIR}/worker-user-data-m5d4x_secret.yaml"
readonly OUTPUT_YAML

oc --as system:admin --context "${CLUSTER_NAME}"  get secrets -n openshift-machine-api worker-user-data -oyaml > "${INPUT_YAML}"

base64_cmd="base64"

UNAME_OUT="$(uname -s)"
readonly UNAME_OUT
case "${UNAME_OUT}" in
    Linux*)     machine=linux;;
    Darwin*)    machine=mac;;
    *)          >&2 echo "[FATAL] Unknow OS" and exit 1;;
esac

if [[ "${machine}" = "mac" ]]; then
    base64_cmd="gbase64"
fi

NEW_VALUE="$(yq -r '.data.userData' ${INPUT_YAML} | ${base64_cmd} -d | jq -c '.ignition.config.append[0].source = "https://api-int.build01.ci.devcluster.openshift.com:22623/config/worker-m5d4x"' | ${base64_cmd} -w0)"
readonly NEW_VALUE

yq --arg userData "${NEW_VALUE}" '.data.userData = $userData' "${INPUT_YAML}" | yq -y '.metadata.name = "worker-user-data-m5d4x"' > "${OUTPUT_YAML}"

echo "The output file are saved ${OUTPUT_YAML}"
