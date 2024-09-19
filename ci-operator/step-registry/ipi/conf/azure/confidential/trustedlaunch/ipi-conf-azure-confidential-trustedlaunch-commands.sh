#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-security.yaml.patch"

# OCPBUGS-36670: encryptionAtHost and settings.securityType are not related.
# feature setting of image definition should only depend on settings.securityType
if [[ "${ENABLE_TRUSTEDLAUNCH_DEFAULT_MACHINE}" == "true" ]]; then
    cat >> "${PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      encryptionAtHost: false
      settings:
        securityType: TrustedLaunch
        trustedLaunch:
          uefiSettings:
            secureBoot: Enabled
            virtualizedTrustedPlatformModule: Enabled
EOF
fi

if [[ "${ENABLE_TRUSTEDLAUNCH_CONTROL_PLANE}" == "true" ]]; then
    cat >> "${PATCH}" << EOF
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
EOF
fi

if [[ "${ENABLE_TRUSTEDLAUNCH_COMPUTE}" == "true" ]]; then
    cat >> "${PATCH}" << EOF
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
fi

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"

cat ${PATCH}
