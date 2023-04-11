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
CI_CREDENTIALS="/var/run/ci-credentials/registry/.dockerconfigjson"

WORKDIR="/tmp"
OPCT_EXEC="/tmp/${BIN_FULLNAME}-latest"

cat <<EOF > "${SHARED_DIR}/install-env"
# OPCT mirroed from ImageStream
export OPCT_IS="${OPCT_IS}"
export BIN_PATH="${BIN_PATH}"
export OPCT_EXEC="${OPCT_EXEC}"
export CI_CREDENTIALS="${CI_CREDENTIALS}"
export WORKDIR=${WORKDIR}

# Results archive information
export AWS_DEFAULT_REGION=us-west-2
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/opct/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive

function show_msg() {
  echo "$(date -u --rfc-3339=seconds)> $@"
}

# Extract OPCT from ImageStream
function extract_opct() {
  pushd ${WORKDIR}
  show_msg "Extracting OPCT binary from image stream ${OPCT_IS}"
  oc image extract ${OPCT_IS} \
    --file=${BIN_PATH} \
    --registry-config=${CI_CREDENTIALS}

  show_msg "Extracted! Moving ./${BIN_FULLNAME} to ${OPCT_EXEC}"
  mv ./${BIN_FULLNAME} ${OPCT_EXEC}

  show_msg "Granting execution permissions"
  chmod u+x ${OPCT_EXEC}

  show_msg "Running ${OPCT_EXEC} version"
  ${OPCT_EXEC} version
  popd
}

# Install awscli
function install_awscli() {
  # Install AWS CLI
  if ! command -v aws &> /dev/null
  then
      show_msg "Installing AWS cli..."
      export PATH="${HOME}/.local/bin:${PATH}"
      if command -v pip3 &> /dev/null
      then
          pip3 install --user awscli
      else
          if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]
          then
            easy_install --user 'pip<21'
            pip install --user awscli
          else
            show_msg "No pip available exiting..."
            exit 1
          fi
      fi
  fi
}
EOF

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

test ! -x "$OPCT_EXEC" && show_msg "OPCT binary $OPCT_EXEC not found, check image stream!"

# Extracting OPCT version
show_msg "Extracting OPCT_VERSION..."
$OPCT_EXEC version | tee "${ARTIFACT_DIR}/opct-version"

OPCT_VERSION=$($OPCT_EXEC version | grep ^OpenShift | grep -Po '(v\d+.\d+.\d+)')


# Populate env var required by OPCT_VERSION
#
# Used on results step
#
show_msg "Getting cluster information/versions..."
DATE_TS=$(date +%Y%m%d)
OCP_VERSION=$(oc get clusterversion version -o=jsonpath='{.status.desired.version}')
OCP_PLAT=$(oc get infrastructures cluster -o jsonpath='{.status.platform}')
OCP_TOPOLOGY=$(oc get infrastructures cluster -o jsonpath='{.status.controlPlaneTopology}')

# Examples:
# OPCT_VERSION/OCP_VERSION-DATE_TS-controlPlaneTopology-provider-platform.tar.gz
# v0.3.0/4.13.0-20230406-HighlyAvailable-vsphere-None.tar.gz
# v0.3.0/4.13.0-20230406-HighlyAvailable-aws-None.tar.gz
# v0.3.0/4.13.0-20230406-HighlyAvailable-aws-AWS.tar.gz
# v0.3.0/4.13.0-20230406-HighlyAvailable-oci-External.tar.gz
# v0.3.0/4.13.0-20230406-HighlyAvailable-oci-Baremetal.tar.gz
# v0.3.0/4.13.0-20230406-SingleReplica-aws-None.tar.gz
OBJECT_PATH="${OPCT_VERSION}/${OCP_VERSION}-${DATE_TS}-${OCP_TOPOLOGY}-${CLUSTER_TYPE}-${OCP_PLAT}.tar.gz"
OBJECT_META="OPCT_VERSION=${OPCT_VERSION},OCP=${OCP_VERSION},Topology=${OCP_TOPOLOGY},Provider=${CLUSTER_TYPE},Platform=${OCP_PLAT}"

# Update install-env script

cat <<EOF >> "${SHARED_DIR}/install-env"

# Required by results
export OPCT_VERSION=${OPCT_VERSION}
export OBJECT_PATH="${OBJECT_PATH}"
export OBJECT_META="${OBJECT_META}"
EOF

cp "${SHARED_DIR}/install-env" "${ARTIFACT_DIR}/install-env"