#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Downloading latest stable
BIN_NAME="openshift-provider-cert"
BIN_OS="linux"
BIN_ARCH="amd64"
BIN_FULLNAME="${BIN_NAME}-${BIN_OS}-${BIN_ARCH}"
BIN_PATH="/usr/bin/${BIN_FULLNAME}"
OPCT_IS="registry.ci.openshift.org/ci/opct:latest"
#OPCT_IS="quay.io/ocp-cert/opct:latest"
# Failed
#CI_CREDENTIALS="${SHARED_DIR}/pull-secret"
CI_CREDENTIALS="/var/run/ci-credentials/registry/.dockerconfigjson"
#CI_CREDENTIALS="/var/run/ci-credentials/registry"
#CI_CREDENTIALS="${SHARED_DIR}/ci-pull-credentials"
# Queue
#CI_CREDENTIALS="/secrets/ci-pull-credentials/.dockerconfigjson"
#CI_CREDENTIALS="/etc/pull-secret/.dockerconfigjson"

WORKDIR="/tmp"
OPCT_EXEC="/tmp/${BIN_FULLNAME}-latest"

echo ">>> debug : ${SHARED_DIR}"
ls -la ${SHARED_DIR} || true

echo ">>> debug : /etc/pull-secret/"
ls -ls /etc/pull-secret/ || true

echo ">>> debug : /var/run/ci-credentials"
ls -la /var/run/ci-credentials || true

echo ">>> debug : /var/run/ci-credentials/registry"
ls -la /var/run/ci-credentials/registry || true

echo ">>> debug : /secrets/ci-pull-credentials"
ls -lsa /secrets/ci-pull-credentials || true

echo ">>> debug : /var/run"
ls -lsa /var/run || true

echo ">> pwd "
echo $PWD
ls -la $PWD

echo ">> writing $PWD "
#touch $PWD/test-marco

echo ">> oc version"
oc version
echo "<<< debug"


cat <<EOF > "${SHARED_DIR}/install-env"
export OPCT_IS="${OPCT_IS}"
export BIN_PATH="${BIN_PATH}"
export OPCT_EXEC="${OPCT_EXEC}"
export CI_CREDENTIALS="${CI_CREDENTIALS}"
export WORKDIR=${WORKDIR}

function extract_opct() {
  pushd ${WORKDIR}
  echo "Extracting OPCT binary from image stream ${OPCT_IS}"
  oc image extract ${OPCT_IS} \
    --file=${BIN_PATH} \
    --registry-config=${CI_CREDENTIALS}

  echo "Extracted! Moving ./${BIN_FULLNAME} to ${OPCT_EXEC}"
  mv ./${BIN_FULLNAME} ${OPCT_EXEC}

  echo "Granting execution permissions"
  chmod u+x ${OPCT_EXEC}

  echo "Running ${OPCT_EXEC} version"
  ${OPCT_EXEC} version
  popd
}
EOF

echo ">> cat ${SHARED_DIR}/install-env"
cat "${SHARED_DIR}/install-env"

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

test ! -x "$OPCT_EXEC" && echo "OPCT binary $OPCT_EXEC not found, check image stream!"

$OPCT_EXEC version | tee "${ARTIFACT_DIR}/opct-version"

OPCT_VERSION=$($OPCT_EXEC version | grep ^OpenShift | grep -Po '(v\d+.\d+.\d+)')

echo "export OPCT_VERSION=${OPCT_VERSION}" >> "${SHARED_DIR}/install-env"

cp "${SHARED_DIR}/install-env" "${ARTIFACT_DIR}/install-env"