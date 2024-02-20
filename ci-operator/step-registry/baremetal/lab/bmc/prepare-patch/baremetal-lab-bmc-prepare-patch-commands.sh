#!/bin/bash

set -o errexit
set -o pipefail

if [ "${AGENT_BM_HOSTS_IN_INSTALL_CONFIG}" != "true" ]; then
  echo "Skipping BMC prepare patch step"
  exit 0
fi

[ -f "${SHARED_DIR}/_bmc_patch_install_config.yaml" ] || echo "{}" >> "${SHARED_DIR}/_bmc_patch_install_config.yaml"

  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/_bmc_patch_install_config.yaml" - <<< "
platform:
  baremetal:
    provisioningNetwork: Disabled
    hosts: []
"
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # See: https://docs.openshift.com/container-platform/4.14/installing/installing_bare_metal_ipi/ipi-install-installation-workflow.html#bmc-addressing-for-dell-idrac_ipi-install-installation-workflow
  # and baremetal-lab-agent-install-commands.sh for IPI bmc configuration
  # disableCertificateVerification not needed when using IPMI protocol
  # Example bmc fields contained in hosts.yaml file
  # bmc_scheme: ipmi
  # bmc_base_uri: /
  # Update 29/11/2023 - try idrac-virtualmedia as suggested by jad https://redhat-internal.slack.com/archives/C049U2HRWJU/p1701245746439309
  # The test will run on Dell x86 servers thus idrac-virtualmedia is supported
  # see the following install-config.yaml for instance: https://mastern-jenkins-csb-openshift-qe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-common/job/Flexy-install/249[…]kdir/install-dir/install-config.yaml
  # address: idrac-virtualmedia://10.1.233.29/redfish/v1/Systems/System.Embedded.1

  AGENT_BMC_INSTALL_CONFIG="
  name: ${name}
  role: ${name%%-[0-9]*}
  rootDeviceHints:
    ${root_device:+deviceName: ${root_device}}
    ${root_dev_hctl:+hctl: ${root_dev_hctl}}
  bmc:
        address: idrac-virtualmedia://${bmc_address}/redfish/v1/Systems/System.Embedded.1
        username: ${bmc_user}
        password: ${bmc_pass}
        disableCertificateVerification: true
  bootMACAddress: ${provisioning_mac}
  interfaces:
  - macAddress: ${mac}
    name: ${baremetal_iface}
  networkConfig:
    interfaces:
    - name: ${baremetal_iface}
      type: ethernet
      state: up
      ipv4:
        enabled: true
        dhcp: false
        address:
            - ip: ${ip}
              prefix-length: ${INTERNAL_NET_CIDR##*/}
      ipv6:
        enabled: false
"

  # split the ipi_disabled_ifaces semi-comma separated list into an array
  IFS=';' read -r -a ipi_disabled_ifaces <<< "${ipi_disabled_ifaces}"
  for iface in "${ipi_disabled_ifaces[@]}"; do
    # Take care of the indentation when adding the disabled interfaces to the above yaml
    AGENT_BMC_INSTALL_CONFIG+="
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
  AGENT_BMC_INSTALL_CONFIG+="
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

  # Patch the install-config.yaml by adding the given host to the hosts list in the platform.baremetal stanza
  yq --inplace eval-all 'select(fileIndex == 0).platform.baremetal.hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
    "$SHARED_DIR/_bmc_patch_install_config.yaml" - <<< "$AGENT_BMC_INSTALL_CONFIG"
done

grep -v "password\|username\|pullSecret" "${SHARED_DIR}/_bmc_patch_install_config.yaml" > "${ARTIFACT_DIR}/_bmc_patch_install_config.yaml" || true