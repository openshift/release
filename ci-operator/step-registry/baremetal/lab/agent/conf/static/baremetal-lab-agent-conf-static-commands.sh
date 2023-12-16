#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export RENDEZVOUS_IP="$(yq -r e -o=j -I=0 ".[0].ip" "${SHARED_DIR}/hosts.yaml")"

INSTALL_DIR="/tmp/installer"
mkdir -p "${INSTALL_DIR}"
git clone -b master https://github.com/openshift-qe/agent-qe.git "${INSTALL_DIR}/agent-qe"

pip install j2cli



INVENTORY="${INSTALL_DIR}/agent-install-inventory.env"


##mac,ip,host,arch,root_device,root_dev_hctl,provisioning_mac,switch_port,switch_port_v2,
##ipi_disabled_ifaces,baremetal_iface,bmc_address,bmc_scheme,bmc_base_uri,bmc_user,bmc_pass,console_kargs,transfer_protocol_type,redfish_user,redfish_password,vendor,pdu_uri

#echo "$(echo -n 'hello'; cat "${SHARED_DIR}/hosts.yaml")" > "${INVENTORY}"


hosts=($(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"))
echo "[hosts]" > ${INVENTORY}
for i in "${!hosts[@]}"; do
    . <(echo "${hosts[$i]}" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    echo "node${i} hostname=${name} role=${name%%-[0-9]*} root_device=${root_device} mac=${mac} baremetal_iface=${baremetal_iface} \
                   ip=${ip} bmc_address=${bmc_address} bmc_user=${bmc_user} bmc_pass=${bmc_pass}" >> ${INVENTORY}
done


cp "${INVENTORY}" "${ARTIFACT_DIR}/"

/alabama/.local/bin/j2 "${INSTALL_DIR}/agent-qe/prow-utils/templates/agent-config.yaml.j2" "${INVENTORY}" -o "${ARTIFACT_DIR}/templated-agent-config.yaml" 


# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  ADAPTED_YAML="
  hostname: ${name}
  role: ${name%%-[0-9]*}
  rootDeviceHints:
    ${root_device:+deviceName: ${root_device}}
    ${root_dev_hctl:+hctl: ${root_dev_hctl}}
  interfaces:
  - macAddress: ${mac}
    name: ${baremetal_iface}
  networkConfig:
    interfaces:
    - name: ${baremetal_iface}
      type: ethernet
      state: up
      ipv4:
        enabled: ${ipv4_enabled}
        dhcp: false
        address:
            - ip: ${ip}
              prefix-length: ${INTERNAL_NET_CIDR##*/}
      ipv6:
        enabled: ${ipv6_enabled}
"

  # split the ipi_disabled_ifaces semi-comma separated list into an array
  IFS=';' read -r -a ipi_disabled_ifaces <<< "${ipi_disabled_ifaces}"
  for iface in "${ipi_disabled_ifaces[@]}"; do
    # Take care of the indentation when adding the disabled interfaces to the above yaml
    ADAPTED_YAML+="
    - name: ${iface}
      type: ethernet
      state: up
      ipv4:
        enabled: false
        dhcp: false
      ipv6:
        enabled: false
        dhcp: false
    "
  done
  
  # Take care of the indentation when adding the dns and routes to the above yaml
  ADAPTED_YAML+="
    dns-resolver:
          config:
            server:
              - ${INTERNAL_NET_IP}
    routes:
      config:
        - destination: 0.0.0.0/0
          next-hop-address: ${INTERNAL_NET_IP}
          next-hop-interface: ${baremetal_iface}
  "
  # Patch the agent-config.yaml by adding the given host to the hosts list in the platform.baremetal stanza
  yq --inplace eval-all 'select(fileIndex == 0).hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
    "$SHARED_DIR/agent-config.yaml" - <<< "$ADAPTED_YAML"
done
