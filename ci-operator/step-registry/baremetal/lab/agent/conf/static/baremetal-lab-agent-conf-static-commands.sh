#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

RENDEZVOUS_IP="$(yq -r e -o=j -I=0 ".[0].ip" "${SHARED_DIR}/hosts.yaml")"

# Create an agent-config file containing only the minimum required configuration

cat > "${SHARED_DIR}/agent-config-unconfigured.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
additionalNTPSources:
- ${AUX_HOST}
EOF

# https://issues.redhat.com/browse/AGENT-677 - Pass BMC details to cluster if provided
# To test this feature the using the BareMetal platform the BMC info should be added to the hosts in install-config.yaml.
# In this case, no hosts should be defined in agent-config.yaml since these will take precedence in order to maintain backwards compatibility.

if [ "${AGENT_BM_HOSTS_IN_INSTALL_CONFIG}" = "false" ]; then
cat > "${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
additionalNTPSources:
- ${AUX_HOST}
hosts: []
EOF

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    # Do not create host config for additional workers if we need to run them as day2 (e.g., to test single-arch clusters based
    # on a single-arch payload migrated to a multi-arch cluster)
    continue
  fi
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

else

cat > "${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
additionalNTPSources:
- ${AUX_HOST}
EOF

fi