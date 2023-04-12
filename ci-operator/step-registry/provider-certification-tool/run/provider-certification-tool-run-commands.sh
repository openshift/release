#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

set -x

# Run the tool with watch flag set.
if [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then

#     cmd_jq="$(which yq 2>/dev/null || true)"
#     if [ ! -x "${cmd_jq}" ]; then
#         CMD_YQ="${WORKDIR}/yq"
#         echo "# jq not found, installing on $cmd_jq..."
#         wget --quiet https://github.com/mikefarah/yq/releases/download/v4.33.3/yq_linux_amd64 \
#             -O $CMD_YQ

#         echo "# granting exec permissions"
#         chmod +x $CMD_YQ
#     fi

#     echo "# extracting version from OCP_CURRENT_CHANNEL=${OCP_CURRENT_CHANNEL}"
#     channel_name="$(echo $OCP_CURRENT_CHANNEL | grep -Po '[a-z]+')"
#     channel_version_xstream="$(echo $OCP_CURRENT_CHANNEL | grep -Po '[0-9]+' | head -n1)"
#     channel_version_ystream="$(echo $OCP_CURRENT_CHANNEL | grep -Po '[0-9]+' | tail -n1)"
#     target_version_ystream="$(echo "$channel_version_ystream + 1 " | bc )"
#     target_version_xy="${channel_version_xstream}.${target_version_ystream}"
#     target_channel="${channel_name}-${target_version_xy}"

#     cat <<EOF > "${ARTIFACT_DIR}/release-versions"
# channel_name=$channel_name
# channel_version_xstream=$channel_version_xstream
# channel_version_ystream=$channel_version_ystream
# target_version_ystream=$target_version_ystream
# target_version_xy=$target_version_xy
# target_channel=$target_channel
# EOF

#     echo "Downloading upgrade graph data..."
#     curl -L -o "${WORKDIR}/cincinnati-graph-data.tar.gz" \
#         https://api.openshift.com/api/upgrades_info/graph-data

#     tar xvzf "${WORKDIR}/cincinnati-graph-data.tar.gz" "channels/${target_channel}.yaml" -C "${WORKDIR}" || true
#     if [ -f "${WORKDIR}/channels/${target_channel}.yaml" ]; then
#         target_release="$($CMD_YQ -r .versions[] "${WORKDIR}/channels/${target_channel}.yaml" | grep "${target_version_xy}." | tail -n1)"
#     else
#         echo "ERROR: Unable to extract/find the channels file from cincinnati: ${WORKDIR}/channels/${target_channel}.yaml
# $(cat "${ARTIFACT_DIR}"/release-versions)

# # files on ${WORKDIR}/channels
# $(ls ${WORKDIR}/channels/)
# "
#         exit 1
#     fi
#     # TODO determine the target version based on the latest available for ${OCP_VERSION}+1
#     RELEASE_IMAGE=$(oc adm release info "${target_release}" -o jsonpath='{.image}')
#     echo "RELEASE_IMAGE=${RELEASE_IMAGE}" | tee -a "${ARTIFACT_DIR}/release-versions"

    echo "Running OPCT with upgrade mode"
    ${OPCT_EXEC} run --watch --mode=upgrade --upgrade-to-image="${TARGET_RELEASE_IMAGE}"
else
    echo "Running OPCT with regular mode"
    ${OPCT_EXEC} run --watch
fi