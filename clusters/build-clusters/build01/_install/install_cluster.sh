#!/bin/bash

### prerequisites
### 1. ~/.aws/credentials contains aws_access_key_id and aws_secret_access_key for an IAMUSER under openshift-ci-infra account

set -o errexit
set -o nounset
set -o pipefail

SCRIPT="$0"
readonly SCRIPT

if [[ "$#" -lt  1 ]]; then
  >&2 echo "[FATAL] Illegal number of parameters"
  >&2 echo "[INFO] usage: $SCRIPT <ocp_version> [path_to_install_config]"
  >&2 echo "[INFO] e.g., $SCRIPT 4.3.0"
  exit 1
fi

OCP_VERSION="$1"
readonly OCP_VERSION

INSTALL_FOLDER="${HOME}/install_openshift/$(date '+%Y%m%d_%H%M%S')"
readonly INSTALL_FOLDER
mkdir -pv "${INSTALL_FOLDER}"

unameOut="$(uname -s)"
readonly unameOut
case "${unameOut}" in
    Linux*)     machine=linux;;
    Darwin*)    machine=mac;;
    *)          >&2 echo "[FATAL] Unknow OS" and exit 1;;
esac

curl -o "${INSTALL_FOLDER}/openshift-install-${machine}-${OCP_VERSION}.tar.gz" "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}/openshift-install-${machine}-${OCP_VERSION}.tar.gz"
tar xzvf "${INSTALL_FOLDER}"/openshift-install*.tar.gz -C "${INSTALL_FOLDER}"

INSTALLER_BIN="${INSTALL_FOLDER}/openshift-install"
readonly INSTALLER_BIN

INSTALL_CONFIG="${2:-${HOME}/install-config.yaml}"
readonly INSTALL_CONFIG

if [[ ! -f "${INSTALL_CONFIG}" ]]; then
  >&2 echo "[FATAL] file not found: install config ${INSTALL_CONFIG} ... specify it with the 2nd arg or copy it to '~/install-config.yaml'"
  >&2 echo "[INFO] create by: ${INSTALLER_BIN}/openshift-install create install-config"
  exit 1
fi

>&2 echo "[INFO] using install config ${INSTALL_CONFIG}"

cp -v "${INSTALL_CONFIG}" "${INSTALL_FOLDER}"
"${INSTALLER_BIN}" create cluster --dir="${INSTALL_FOLDER}" --log-level=debug
