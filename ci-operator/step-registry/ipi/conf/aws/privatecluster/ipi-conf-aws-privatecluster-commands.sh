#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"


# subnet and AZs
allsubnetids="${SHARED_DIR}/allsubnetids"
availabilityzones="${SHARED_DIR}/availabilityzones"
if [ ! -f "${allsubnetids}" ] || [ ! -f "${availabilityzones}" ]; then
    echo "File ${allsubnetids} or ${availabilityzones} does not exist."
    exit 1
fi

echo -e "subnets: $(cat ${allsubnetids})"
echo -e "AZs: $(cat ${availabilityzones})"

CONFIG_PRIVATE_CLUSTER="${SHARED_DIR}/install-config-private.yaml.patch"
cat > "${CONFIG_PRIVATE_CLUSTER}" << EOF
publish: Internal
platform:
  aws:
    subnets: $(cat "${allsubnetids}")
controlPlane:
  platform:
    aws:
      zones: $(cat "${availabilityzones}")
compute:
- platform:
    aws:
      zones: $(cat "${availabilityzones}")
EOF

/tmp/yq m -x -i "${CONFIG}" "${CONFIG_PRIVATE_CLUSTER}"

# Print install-config:
echo "install-config.yaml:"
echo '{pullSecret: dummy, proxy: {httpProxy: dummy, httpsProxy: dummy}, additionalTrustBundle: dummy}' > /tmp/dummy
/tmp/yq m --overwrite --autocreate=false "${CONFIG}" /tmp/dummy

find "${SHARED_DIR}"/ -type f ! -name 'install-config*' -exec cp "{}" "${ARTIFACT_DIR}/"  \;
