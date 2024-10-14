#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ "${MIRROR_BIN}" != "oc-mirror" ]]; then
  echo "users specifically do not use oc-mirror to run mirror"
  exit 0
fi

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Get mirror setting for install-config.yaml
idms_file="${SHARED_DIR}/idms-oc-mirror.yaml"
itms_file="${SHARED_DIR}/itms-oc-mirror.yaml"
if [ ! -s "${idms_file}" ]; then
    echo "${idms_file} not found, exit..."
    exit 1
else
    run_command "cat '${idms_file}'"
fi

key_name="imageContentSources"
if [[ "${ENABLE_IDMS}" == "yes" ]]; then
    key_name="imageDigestSources"
fi
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
yq-v4 --prettyPrint eval-all "{\"$key_name\": .spec.imageDigestMirrors}" "${idms_file}" > "${install_config_mirror_patch}" || exit 1

if [ -s "${itms_file}" ]; then
    echo "${itms_file} found"
    run_command "cat '${itms_file}'"
    new_data=$(yq-v4 eval-all '.spec.imageTagMirrors' "${itms_file}") yq-v4 eval-all  ".$key_name += env(new_data)" -i "${install_config_mirror_patch}" || exit 1
fi

# Ending
run_command "cat '${install_config_mirror_patch}'"
