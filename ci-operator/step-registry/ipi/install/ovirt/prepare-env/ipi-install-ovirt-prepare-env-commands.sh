#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi
echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

mkdir ${ARTIFACT_DIR}/installer
cp "${CLUSTER_PROFILE_DIR}/csi-test-manifest.yaml" "${SHARED_DIR}"

# we need jq for later rhcos url extraction
(curl -L -o "${SHARED_DIR}"/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 2>/dev/null && chmod +x /tmp/bin/jq)
if ! command -V /tmp/bin/jq; then
    echo "Failed to fetch jq"
    exit 1
fi

cat <<_EOF_ > "${SHARED_DIR}"/ovirt-event-functions.sh
function send_event_to_ovirt(){
local install_state="Installed"
local build_id=${BUILD_ID}

if [ "$#" -eq 1  ] ; then
    install_state=$1
fi

#take the last 7 chars from the id and convert it to int
printf -v build_id '%d\n' $((10#${build_id: -7})) # ${build_id: -7}
epoch=$(date +'%s')
cat <<__EOF__ > ${ARTIFACT_DIR}/installer/event.xml
<event>
  <description>Openshift CI - cluster installation;${OCP_CLUSTER};${install_state};${JOB_SPEC} ;${rchos_image} </description>
  <severity>normal</severity>
  <origin>openshift-ci</origin>
  <custom_id>$((${epoch}+${build_id}))</custom_id>
</event>
__EOF__


  curl --insecure  \
  --request POST \
  --header "Accept: application/xml"  \
  --header "Content-Type: application/xml" \
  -u "${OVIRT_ENGINE_USERNAME}:${OVIRT_ENGINE_PASSWORD}" \
  -d @${ARTIFACT_DIR}/installer/event.xml \
  ${OVIRT_ENGINE_URL}/events || true

}
_EOF_