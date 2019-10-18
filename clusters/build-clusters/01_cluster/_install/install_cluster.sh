#!/bin/bash

### prerequisites
### 1. (latest version of) /usr/bin/oc, otherwise download https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/
### 2. ~/.aws/credentials contains aws_access_key_id and aws_secret_access_key for an IAMUSER under openshift-ci-infra account
### 3. ~/.docker/config.json contains auth entry for registry.svc.ci.openshift.org and the entries from the pull secret
###    the pull secret used in the install-config.yaml has to include all auth entries above
###    https://mojo.redhat.com/docs/DOC-1081313#jive_content_id_Deploying_test_clusters_off_CI_builds

### find a release image: 
### ocp: https://openshift-release.svc.ci.openshift.org/
### okd: https://origin-release.svc.ci.openshift.org

set -o errexit
set -o nounset
set -o pipefail

SCRIPT="$0"
readonly SCRIPT

if [[ "$#" -lt  1 ]]; then
  >&2 echo "[FATAL] Illegal number of parameters"
  >&2 echo "[INFO] usage: $SCRIPT <release> [path_to_install_config]"
  >&2 echo "[INFO] e.g., $SCRIPT registry.svc.ci.openshift.org/ocp/release:4.2.0-0.nightly-2019-10-08-232417"
  exit 1
fi

RELEASE_IMAGE="$1"
readonly RELEASE_IMAGE

OC_CLI="/usr/bin/oc"
readonly OC_CLI

INSTALL_FOLDER="${HOME}/install_openshift/$(date '+%Y%m%d_%H%M%S')"
readonly INSTALL_FOLDER
mkdir -pv "${INSTALL_FOLDER}"

"$OC_CLI" adm release extract --tools "${RELEASE_IMAGE}" --to="${INSTALL_FOLDER}"
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
