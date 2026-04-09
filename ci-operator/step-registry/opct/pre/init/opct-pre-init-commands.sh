#!/bin/bash

#
# Initialize OPCT configuration used across steps in pipeline.
# OPCT binary is extracted on every step from image stream
# (mirrored by CI) or an user defined image from Quay.
#

set -o nounset
set -o errexit
set -o pipefail

# Downloading latest stable
CI_CREDENTIALS="/var/run/ci-credentials/registry/.dockerconfigjson"
WORKDIR="/tmp"

declare -g IMAGE_EXTRACT_OPTS
OPCT_CLI_NAME="opct"
OPCT_CLI_PATH_IMAGE=/usr/bin/${OPCT_CLI_NAME}
OPCT_CLI=${WORKDIR}/${OPCT_CLI_NAME}

if [[ "${OPCT_CLI_IMAGE}" =~ ^'pipeline'* ]]; then
  NEW_IMAGE="image-registry.openshift-image-registry.svc.cluster.local:5000/${NAMESPACE}/${OPCT_CLI_IMAGE}"
  echo "Overriding OPCT_CLI_IMAGE image from ${OPCT_CLI_IMAGE} to ${NEW_IMAGE}"
  OPCT_CLI_IMAGE=${NEW_IMAGE}
  IMAGE_EXTRACT_OPTS="--insecure=true"
fi

cat <<EOF > "${SHARED_DIR}/env"
# Workdir used across opct steps
export WORKDIR="${WORKDIR}"

# OPCT mirroed from image repository
export OPCT_CLI="${OPCT_CLI}"

# AWS Credentials ref to store the results (baseline)
export AWS_DEFAULT_REGION=us-east-1
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/opct/.awscred-vmc-ci-opct-uploader
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive

function show_msg() {
  echo -e "$(date -u --rfc-3339=seconds)> \$@"
}

# Extract OPCT from ImageStream
function extract_opct() {
  pushd ${WORKDIR}
  show_msg "Extracting OPCT binary from image stream ${OPCT_CLI_IMAGE}"

  timeout 3m bash -c "until \
      oc image extract ${OPCT_CLI_IMAGE} ${IMAGE_EXTRACT_OPTS-} --registry-config=${CI_CREDENTIALS} --file=${OPCT_CLI_PATH_IMAGE} >/dev/null; \
      do
        show_msg 'retrying in 15s...' && sleep 15;\
      done"

  chmod u+x ${OPCT_CLI}
  show_msg "Running ${OPCT_CLI} version"
  ${OPCT_CLI} version
  #popd
}

function dump_opct_namespace() {
  rc=\$?
  if [[ \$rc -ne 0 ]]; then
    show_msg "Dumping namespace"
    oc adm inspect ns/opct --dest-dir=${WORKDIR}/opct-inspect || true
    tar cfz \${ARTIFACT_DIR}/oc-inspect-opct.tar.gz ${WORKDIR}/opct-inspect || true
  fi
  show_msg "Done with code=\$rc"
  exit \$rc
}
export -f dump_opct_namespace
EOF

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
extract_opct

if [[ ! -x "${OPCT_CLI}" ]]; then
  show_msg "OPCT binary ${OPCT_CLI} not found, check image stream!"
  exit 1
fi

# Extracting OPCT version
show_msg "Extracting OPCT_VERSION..."
${OPCT_CLI} version | tee "${ARTIFACT_DIR}/opct-version"

OPCT_VERSION=$($OPCT_CLI version | grep ^"OPCT CLI" | awk -F': ' '{print$2}' | awk -F'+' '{print$1}' || true)
OPCT_MODE="${OPCT_RUN_MODE:-default}"

# Update env script
cat <<EOF >> "${SHARED_DIR}/env"

# Required by setup
export OPCT_VERSION="${OPCT_VERSION}"
export OPCT_MODE="${OPCT_MODE}"
EOF

cp "${SHARED_DIR}/env" "${ARTIFACT_DIR}/env"
