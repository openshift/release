#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to configure redfish virtual media"
cat > "$SHARED_DIR/static_v6_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    provisioningNetwork: Disabled
    hosts:
EOF

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "$SHARED_DIR/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  cat >> "$SHARED_DIR/static_v6_patch_install_config.yaml" <<EOF
    - name: ${name}
      role: ${name%%-[0-9]*}
      bootMACAddress: ${mac}
      rootDeviceHints:
        ${root_device:+deviceName: ${root_device}}
        ${root_dev_hctl:+hctl: ${root_dev_hctl}}
      bmc:
        address: ${redfish_scheme}://${bmc_address}${redfish_base_uri}
        disableCertificateVerification: true
        username: ${redfish_user}
        password: ${redfish_password}
      networkConfig:
        interfaces:
        - name: ${baremetal_iface}
          type: ethernet
          state: up
          ipv4:
            enabled: ${ipv4_enabled}
          ipv6:
            dhcp: false
            address:
            - ip: ${ipv6}
              prefix-length: ${INTERNAL_NET_V6_CIDR##*/}
            enabled: ${ipv6_enabled}
EOF

  # Append configurations for disabled interfaces
  IFS=';' read -r -a ipi_disabled_ifaces <<< "${ipi_disabled_ifaces}"
  for iface in "${ipi_disabled_ifaces[@]}"; do
    cat >> "$SHARED_DIR/static_v6_patch_install_config.yaml" <<EOF
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
  cat >> "$SHARED_DIR/static_v6_patch_install_config.yaml" <<EOF
        dns-resolver:
          config:
            server:
            - ${INTERNAL_NET_IPV6}
        routes:
          config:
          - destination: ::/0
            next-hop-address: ${INTERNAL_NET_IPV6}
            next-hop-interface: ${baremetal_iface}
EOF
  cat >> "$SHARED_DIR/static_v6_patch_install_config.yaml" <<EOF
EOF
done
