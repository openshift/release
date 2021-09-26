#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"

if [ ! -f "${SHARED_DIR}/allsubnetids" ]; then
    echo "File ${SHARED_DIR}/allsubnetids does not exist."
    exit 1
fi

subnets="$(cat "${SHARED_DIR}/allsubnetids")"
echo "subnets: ${subnets}"


CONFIG_PRIVATE_CLUSTER="${SHARED_DIR}/install-config-private.yaml.patch"
cat > "${CONFIG_PRIVATE_CLUSTER}" << EOF
publish: Internal
platform:
  aws:
    subnets: ${subnets}
EOF

/tmp/yq m -x -i "${CONFIG}" "${CONFIG_PRIVATE_CLUSTER}"

# zones were added in ipi-conf-aws
# but when using byo VPC, we cannot ensure zones and subnets match
# so, remove it for private cluster
# TODO: ensure selected zones and subnet match
/tmp/yq d -i "${CONFIG}" 'controlPlane.platform.aws.zones'
/tmp/yq d -i "${CONFIG}" 'compute[0].platform.aws.zones'
