#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

QUERY=".[0].ip"
if [ "${ipv6_enabled:-}" == "true" ]; then
 QUERY=".[0].ipv6"
fi
RENDEZVOUS_IP="$(yq -r e -o=j -I=0 "${QUERY}" "${SHARED_DIR}/hosts.yaml")"

day2_arch="$(echo "${ADDITIONAL_WORKER_ARCHITECTURE}" | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

# Create an agent-config file containing only the minimum required configuration

ntp_host=$(< "${CLUSTER_PROFILE_DIR}/aux-host-internal-name")
cat > "${SHARED_DIR}/agent-config-unconfigured.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
additionalNTPSources:
- ${ntp_host}
EOF

cat > "${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
additionalNTPSources:
- ${ntp_host}
hosts: []
EOF

cat > "${SHARED_DIR}/nodes-config.yaml" <<EOF
cpuArchitecture: ${day2_arch}
hosts: []
EOF

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" != *-a-* ]] || [ "${ADDITIONAL_WORKERS_DAY2}" != "true" ]; then
    ADAPTED_YAML="
  role: ${name%%-[0-9]*}"
  else
    ADAPTED_YAML=""
  fi

  ADAPTED_YAML+="
  rootDeviceHints:
    ${root_device:+deviceName: ${root_device}}
    ${root_dev_hctl:+hctl: ${root_dev_hctl}}
  hostname: ${name}
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
        dhcp: ${ipv4_enabled}
      ipv6:
        enabled: ${ipv6_enabled}
        dhcp: ${ipv6_enabled}
        auto-gateway: ${ipv6_enabled}
        auto-routes: ${ipv6_enabled}
        autoconf: ${ipv6_enabled}
        auto-dns: ${ipv6_enabled}
"

# Workaround: Comment out this code until OCPBUGS-34849 is fixed
#  # split the ipi_disabled_ifaces semi-comma separated list into an array
#  IFS=';' read -r -a ipi_disabled_ifaces <<< "${ipi_disabled_ifaces}"
#  for iface in "${ipi_disabled_ifaces[@]}"; do
#    # Take care of the indentation when adding the disabled interfaces to the above yaml
#    ADAPTED_YAML+="
#    - name: ${iface}
#      type: ethernet
#      state: up
#      ipv4:
#        enabled: false
#        dhcp: false
#      ipv6:
#        enabled: false
#        dhcp: false
#    "
#  done
  # Patch agent-config.yaml or nodes-config.yaml if host used for day2 by adding the given host to the hosts list
  CONFIG_FILE=agent-config.yaml
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    CONFIG_FILE="nodes-config.yaml"
  fi
  yq --inplace eval-all 'select(fileIndex == 0).hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
      "$SHARED_DIR/$CONFIG_FILE" - <<< "$ADAPTED_YAML"
done
