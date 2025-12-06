#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Determine certificate verification setting based on BMC_VERIFY_CA
if [ "${BMC_VERIFY_CA:-false}" == "true" ]; then
  DISABLE_CERT_VERIFICATION="false"
else
  DISABLE_CERT_VERIFICATION="true"
fi

echo "Creating patch file to configure redfish virtual media"
cat > "$SHARED_DIR/redfish_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    provisioningNetwork: Disabled
    hosts:
EOF

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "$SHARED_DIR/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    # Do not add additional workers if we need to run them as day2 (e.g., to test cluster-api)
    echo "{INFO} Additional worker ${name} will be added as day2 operation"
    continue
  fi
  cat >> "$SHARED_DIR/redfish_patch_install_config.yaml" <<EOF
    - name: ${name}
      role: ${name%%-[0-9]*}
      bootMACAddress: ${mac}
      rootDeviceHints:
        ${root_device:+deviceName: ${root_device}}
        ${root_dev_hctl:+hctl: ${root_dev_hctl}}
      bmc:
        address: ${redfish_scheme}://${bmc_address}${redfish_base_uri}
        disableCertificateVerification: ${DISABLE_CERT_VERIFICATION}
        username: ${redfish_user}
        password: ${redfish_password}
      networkConfig:
        interfaces:
        - name: ${baremetal_iface}
          type: ethernet
          state: up
          ipv4:
            enabled: ${ipv4_enabled}
            dhcp: ${ipv4_enabled}
          ipv6:
            enabled: ${ipv6_enabled}
            dhcp: ${ipv6_enabled}
            autoconf: ${ipv6_enabled}
            auto-gateway: ${ipv6_enabled}
            auto-routes: ${ipv6_enabled}
            auto-dns: ${ipv6_enabled}
EOF

  # Append configurations for disabled interfaces
  IFS=';' read -r -a ipi_disabled_ifaces <<< "${ipi_disabled_ifaces}"
  for iface in "${ipi_disabled_ifaces[@]}"; do
    cat >> "$SHARED_DIR/redfish_patch_install_config.yaml" <<EOF
        - name: ${iface}
          type: ethernet
          state: up
          ipv4:
            enabled: false
            dhcp: false
          ipv6:
            enabled: false
            dhcp: false
EOF
  done

  cat >> "$SHARED_DIR/redfish_patch_install_config.yaml" <<EOF
EOF
done
