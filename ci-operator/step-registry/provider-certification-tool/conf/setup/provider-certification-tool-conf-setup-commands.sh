#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Downloading latest stable
CI_CREDENTIALS="/var/run/ci-credentials/registry/.dockerconfigjson"
WORKDIR="/tmp"

declare -g IMAGE_EXTRACT_OPTS
OPCT_CLI_NAME="opct"
OPCT_CLI_PATH_IMAGE=/usr/bin/${OPCT_CLI_NAME}
OPCT_CLI=/tmp/${OPCT_CLI_NAME}
WORKDIR=/tmp

if [[ "${OPCT_CLI_IMAGE}" =~ ^'pipeline'* ]]; then
  NEW_IMAGE="image-registry.openshift-image-registry.svc.cluster.local:5000/${NAMESPACE}/${OPCT_CLI_IMAGE}"
  echo "Overriding OPCT_CLI_IMAGE image from ${OPCT_CLI_IMAGE} to ${NEW_IMAGE}"
  OPCT_CLI_IMAGE=${NEW_IMAGE}
  IMAGE_EXTRACT_OPTS="--insecure=true"
fi

cat <<EOF > "${SHARED_DIR}/env"
# OPCT mirroed from ImageStream
export OPCT_CLI="${OPCT_CLI}"
export CI_CREDENTIALS="${CI_CREDENTIALS}"
export WORKDIR=${WORKDIR}

# Results archive information
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
  oc image extract ${OPCT_CLI_IMAGE} ${IMAGE_EXTRACT_OPTS-} \
    --registry-config=${CI_CREDENTIALS} \
    --file=${OPCT_CLI_PATH_IMAGE} && \
    chmod u+x ${OPCT_CLI}
  
  show_msg "Running ${OPCT_CLI} version"
  ${OPCT_CLI} version
  popd
}
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
$OPCT_CLI version | tee "${ARTIFACT_DIR}/opct-version"

OPCT_VERSION=$($OPCT_CLI version | grep ^"OPCT CLI" | awk -F': ' '{print$2}' | awk -F'+' '{print$1}' || true)
OPCT_MODE="${OPCT_RUN_MODE:-default}"

# Populate env var required by OPCT_VERSION
#
# Used on results step
#
show_msg "Getting cluster information/versions..."
DATE_TS=$(date +%Y%m%d)
OCP_PLAT=$(oc get infrastructures cluster -o jsonpath='{.status.platform}')
OCP_TOPOLOGY=$(oc get infrastructures cluster -o jsonpath='{.status.controlPlaneTopology}')
OCP_VERSION=$(oc get clusterversion version -o=jsonpath='{.status.desired.version}')

current_version_x=$(echo "$OCP_VERSION" | awk -F'.' '{ print$1 }')
current_version_y=$(echo "$OCP_VERSION" | awk -F'.' '{ print$2 }')
OCP_VERSION_BASELINE="${current_version_x}.${current_version_y}"

# Populate the required variables to run conformance upgrade
# The steps below will discovers the stable 4.y+1 based on the
# cincinnati graph data, then extract the Image Digest and set it as
# env var consumed by the 'run' step.
if [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then
  pushd ${WORKDIR}

  echo "Installing yq"
  cmd_yq="$(which yq 2>/dev/null || true)"
  mkdir -p /tmp/bin
  if [ ! -x "${cmd_yq}" ]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
        -o /tmp/bin/yq && chmod +x /tmp/bin/yq
  fi
  PATH=${PATH}:/tmp/bin
  export PATH
  cmd_yq="$(which yq 2>/dev/null || true)"

  UPGRADE_TO_CHANNEL_TYPE="${UPGRADE_TO_CHANNEL_TYPE:-stable}"
  target_version_y=$(( current_version_y + 1 ))
  target_version_xy="${current_version_x}.${target_version_y}"
  upgrade_to_channel="${UPGRADE_TO_CHANNEL_TYPE}-${current_version_x}.${target_version_y}"

  cat <<EOF > "${ARTIFACT_DIR}/release-versions"
UPGRADE_TO_CHANNEL_TYPE=$UPGRADE_TO_CHANNEL_TYPE
current_version_x=$current_version_x
current_version_y=$current_version_y
target_version_y=$target_version_y
target_version_xy=$target_version_xy
upgrade_to_channel=$upgrade_to_channel
EOF

  echo "Downloading upgrade graph data..."
  curl -L -o "${WORKDIR}/cincinnati-graph-data.tar.gz" \
    https://api.openshift.com/api/upgrades_info/graph-data

  tar xvzf "${WORKDIR}/cincinnati-graph-data.tar.gz" "channels/${upgrade_to_channel}.yaml" -C "${WORKDIR}" || true
  if [ ! -f "${WORKDIR}/channels/${upgrade_to_channel}.yaml" ]; then
    echo "ERROR: Unable to extract/find the channels file from cincinnati: ${WORKDIR}/channels/${upgrade_to_channel}.yaml
$(cat "${ARTIFACT_DIR}"/release-versions)

# files on ${WORKDIR}/channels
$(ls ${WORKDIR}/channels/)
"
    exit 1
  fi

  echo "Looking for target version..."
  target_release="$($cmd_yq -r .versions[] "${WORKDIR}/channels/${upgrade_to_channel}.yaml" | grep "${target_version_xy}." | tail -n1)"

  echo "Found target version [${target_release}], getting Digest..."
  TARGET_RELEASE_IMAGE=$(oc adm release info "${target_release}" -o jsonpath='{.image}')
  popd
fi

# Object path examples:
# OPCT_VERSION/OPCT_RUN_MODE/OCP_VERSION-DATE_TS-controlPlaneTopology-provider-platform.tar.gz
# v0.3.0/default/4.13.0-20230406-HighlyAvailable-vsphere-None.tar.gz
# v0.3.0/upgrade/4.13.0-20230406-HighlyAvailable-vsphere-None.tar.gz
# v0.3.0/default/4.13.0-20230406-HighlyAvailable-aws-None.tar.gz
# v0.3.0/default/4.13.0-20230406-HighlyAvailable-aws-AWS.tar.gz
# v0.3.0/default/4.13.0-20230406-HighlyAvailable-oci-External.tar.gz
# v0.3.0/default/4.13.0-20230406-HighlyAvailable-oci-Baremetal.tar.gz
# v0.3.0/default/4.13.0-20230406-SingleReplica-aws-None.tar.gz
# v0.3.0/default/4.13.0-20230406-SingleReplica-aws-None.tar.gz
OBJECT_PATH="${OPCT_VERSION}/${OPCT_MODE}/${OCP_VERSION}-${DATE_TS}-${OCP_TOPOLOGY}-${CLUSTER_TYPE}-${OCP_PLAT}.tar.gz"
OBJECT_META="OPCT_VERSION=${OPCT_VERSION},OPCT_MODE=${OPCT_MODE},OCP=${OCP_VERSION},Topology=${OCP_TOPOLOGY},Provider=${CLUSTER_TYPE},Platform=${OCP_PLAT}"

# Update install-env script

cat <<EOF >> "${SHARED_DIR}/env"

# Required by results
export OCP_PLAT_TYPE="${OCP_PLAT}"
export OCP_VERSION_BASELINE="${OCP_VERSION_BASELINE}"
export OPCT_VERSION="${OPCT_VERSION}"
export OBJECT_PATH="${OBJECT_PATH}"
export OBJECT_META="${OBJECT_META}"
export TARGET_RELEASE_IMAGE="${TARGET_RELEASE_IMAGE:-}"
EOF

cp "${SHARED_DIR}/env" "${ARTIFACT_DIR}/env"
