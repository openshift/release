#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "$(date -u --rfc-3339=seconds) - additional tags defined, appending to platform spec"
PATCH="${SHARED_DIR}/additional_tags.yaml.patch"
cat >"${PATCH}" <<EOF
platform:
  vsphere:
    failureDomains:
    - topology:
        tagIDs:
$(cat ${SHARED_DIR}/tags_lists | awk -F "," '{print "          - "$2}')
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
