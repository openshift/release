#!/bin/bash

#
# Setup OPCT environment by extracting cluster information.
#

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"

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

# Populate the required variables to run conformance upgrade.
# TARGET_RELEASE_IMAGE comes straight from the "release:latest" dependency
# (OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE), which ci-operator already
# resolves to the exact pullspec declared by the job's releases.latest
# config. This avoids re-deriving the target via a Cincinnati channel-graph
# crawl, which only ever assumed a same-major next-minor target and broke
# on cross-major jumps (e.g. 4.22 -> 5.0).
if [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then
  if [ -z "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}" ]; then
    echo "ERROR: OPCT_RUN_MODE=upgrade requires the release:latest dependency (OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE) to be set."
    exit 1
  fi
  TARGET_RELEASE_IMAGE="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
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
# shellcheck disable=SC2153
OBJECT_PATH="${OPCT_VERSION}/${OPCT_MODE}/${OCP_VERSION}-${DATE_TS}-${OCP_TOPOLOGY}-${CLUSTER_TYPE}-${OCP_PLAT}.tar.gz"
OBJECT_META="OPCT_VERSION=${OPCT_VERSION},OPCT_MODE=${OPCT_MODE},OCP=${OCP_VERSION},Topology=${OCP_TOPOLOGY},Provider=${CLUSTER_TYPE},Platform=${OCP_PLAT}"

# Update env script
cat <<EOF >> "${SHARED_DIR}/env"

# Required by results
export OCP_PLAT_TYPE="${OCP_PLAT}"
export OCP_VERSION_BASELINE="${OCP_VERSION_BASELINE}"
export OBJECT_PATH="${OBJECT_PATH}"
export OBJECT_META="${OBJECT_META}"
export TARGET_RELEASE_IMAGE="${TARGET_RELEASE_IMAGE:-}"
EOF

cp "${SHARED_DIR}/env" "${ARTIFACT_DIR}/env"
