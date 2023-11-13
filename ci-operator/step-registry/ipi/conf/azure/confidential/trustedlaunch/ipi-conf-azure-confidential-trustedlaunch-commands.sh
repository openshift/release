#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-security.yaml.patch"
cat > "${PATCH}" << EOF
controlPlane:
  platform:
    azure:
      encryptionAtHost: true
      settings:
        securityType: TrustedLaunch
        trustedLaunch:
          uefiSettings:
            secureBoot: Enabled
            virtualizedTrustedPlatformModule: Enabled
compute:
- platform:
    azure:
      encryptionAtHost: true
      settings:
        securityType: TrustedLaunch
        trustedLaunch:
          uefiSettings:
            secureBoot: Enabled
            virtualizedTrustedPlatformModule: Enabled
EOF

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"

cat ${PATCH}
