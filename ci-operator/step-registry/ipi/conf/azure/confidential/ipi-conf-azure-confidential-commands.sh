#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-security.yaml.patch"

# OCPBUGS-36670: encryptionAtHost and settings.securityType are not related.
# feature setting of image definition should only depend on settings.securityType
if [[ "${ENABLE_CONFIDENTIAL_DEFAULT_MACHINE}" == "true" ]]; then
    cat >> "${PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      encryptionAtHost: ${ENABLE_ENCRYPTIONATHOST_DEFAULT_MACHINE}
      settings:
        securityType: ${AZURE_SECURITY_TYPE}
        ${AZURE_SECURITY_TYPE,}:
          uefiSettings:
            secureBoot: Enabled
            virtualizedTrustedPlatformModule: Enabled
EOF
    if [[ -n "${OS_DISK_SECURITY_ENCRYPTION_TYPE}" ]]; then
        cat >> "${PATCH}" << EOF
      osDisk:
        securityProfile:
          securityEncryptionType: ${OS_DISK_SECURITY_ENCRYPTION_TYPE}
EOF
    fi
fi

if [[ "${ENABLE_CONFIDENTIAL_CONTROL_PLANE}" == "true" ]]; then
    cat >> "${PATCH}" << EOF
controlPlane:
  platform:
    azure:
      encryptionAtHost: ${ENABLE_ENCRYPTIONATHOST_CONTROL_PLANE}
      settings:
        securityType: ${AZURE_SECURITY_TYPE}
        ${AZURE_SECURITY_TYPE,}:
          uefiSettings:
            secureBoot: Enabled
            virtualizedTrustedPlatformModule: Enabled
EOF
    if [[ -n "${OS_DISK_SECURITY_ENCRYPTION_TYPE}" ]]; then
        cat >> "${PATCH}" << EOF
      osDisk:
        securityProfile:
          securityEncryptionType: ${OS_DISK_SECURITY_ENCRYPTION_TYPE}
EOF
    fi
fi

if [[ "${ENABLE_CONFIDENTIAL_COMPUTE}" == "true" ]]; then
    cat >> "${PATCH}" << EOF
compute:
- platform:
    azure:
      encryptionAtHost: ${ENABLE_ENCRYPTIONATHOST_COMPUTE}
      settings:
        securityType: ${AZURE_SECURITY_TYPE}
        ${AZURE_SECURITY_TYPE,}:
          uefiSettings:
            secureBoot: Enabled
            virtualizedTrustedPlatformModule: Enabled
EOF
    if [[ -n "${OS_DISK_SECURITY_ENCRYPTION_TYPE}" ]]; then
        cat >> "${PATCH}" << EOF
      osDisk:
        securityProfile:
          securityEncryptionType: ${OS_DISK_SECURITY_ENCRYPTION_TYPE}
EOF
    fi
fi

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"

cat ${PATCH}
