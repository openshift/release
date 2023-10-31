#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/user-labels-tags.yaml.patch"
cat > "${PATCH}" << EOF
platform:
  gcp:
EOF

# user labels
i=0
printf '%s' "${USER_LABELS:-}" | while read -r KEY VALUE || [ -n "${KEY}" ]
do
  yq-go write -i "${PATCH}" "platform.gcp.userLabels[$i].key" "${KEY}"
  yq-go write -i "${PATCH}" "platform.gcp.userLabels[$i].value" "${VALUE}"
  i=$(( $i + 1))
done

# user tags
i=0
printf '%s' "${USER_TAGS:-}" | while read -r PARENT KEY VALUE || [ -n "${PARENT}" ]
do
  yq-go write -i "${PATCH}" "platform.gcp.userTags[$i].parentID" "${PARENT}"
  yq-go write -i "${PATCH}" "platform.gcp.userTags[$i].key" "${KEY}"
  yq-go write -i "${PATCH}" "platform.gcp.userTags[$i].value" "${VALUE}"
  i=$(( $i + 1))
done

yq-go m -x -i "${CONFIG}" "${PATCH}"
yq-go r "${CONFIG}" platform

rm "${PATCH}"
