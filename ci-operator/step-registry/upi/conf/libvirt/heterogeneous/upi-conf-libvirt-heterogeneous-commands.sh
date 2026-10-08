#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

require_commands() {
  local cmd
  local -a missing=()

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    printf 'ERROR: missing dependencies: %s\n' "${missing[*]}" >&2
    printf 'Fix the step image before retrying.\n' >&2
    exit 1
  fi
}

require_commands yq-v4 cat base64

# Ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "ERROR: LEASED_RESOURCE is not set (failed to acquire lease)"
  exit 1
fi

# Ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "ERROR: Couldn't find lease config file at ${CLUSTER_PROFILE_DIR}/leases"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"

# Verify lease record exists for LEASED_RESOURCE
if [[ "$(yq-v4 -oy "has(\"${LEASED_RESOURCE}\")" "${LEASE_CONF}")" != "true" ]]; then
  echo "ERROR: Leased resource '${LEASED_RESOURCE}' not found in ${LEASE_CONF}"
  exit 1
fi

function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" || "${lookup}" == "null" ]]; then
    echo "ERROR: Couldn't find '${1}' in lease config for '${LEASED_RESOURCE}'" >&2
    exit 1
  fi
  echo "$lookup"
}

# Ensure pull secret and ssh keys are present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  echo "ERROR: Couldn't find pull secret file at ${CLUSTER_PROFILE_DIR}/pull-secret"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
  echo "ERROR: Couldn't find ssh publickey file at ${CLUSTER_PROFILE_DIR}/ssh-publickey"
  exit 1
fi

# Validate required lease fields and static topology
HOSTNAME_PRIMARY="$(leaseLookup 'hostname')"
HOSTNAME_ADDITIONAL="$(leaseLookup 'hostname-additional')"
SUBNET="$(leaseLookup 'subnet')"
HTTPD_IP="$(leaseLookup 'httpd-ip')"
HTTPD_PORT="$(leaseLookup 'httpd-port')"

# Node count validation
CP_COUNT=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"control-plane\" | length" "${LEASE_CONF}")
COMPUTE_COUNT_LEASE=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".compute | length" "${LEASE_CONF}")
ADD_COMPUTE_COUNT_LEASE=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"additional-compute\" | length" "${LEASE_CONF}")
BOOTSTRAP_COUNT_LEASE=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".bootstrap | length" "${LEASE_CONF}")

if [[ "${BOOTSTRAP_COUNT_LEASE}" -lt 1 ]]; then
  echo "ERROR: Expected at least 1 bootstrap entry in lease, found ${BOOTSTRAP_COUNT_LEASE}"
  exit 1
fi

if [[ "${CP_COUNT}" -ne "${CONTROL_COUNT:-3}" ]]; then
  echo "ERROR: Expected ${CONTROL_COUNT:-3} control-plane nodes in lease, found ${CP_COUNT}"
  exit 1
fi

if [[ "${COMPUTE_COUNT_LEASE}" -ne "${COMPUTE_COUNT:-1}" ]]; then
  echo "ERROR: Expected ${COMPUTE_COUNT:-1} base compute nodes in lease, found ${COMPUTE_COUNT_LEASE}"
  exit 1
fi

if [[ "${ADD_COMPUTE_COUNT_LEASE}" -ne "${ADDITIONAL_WORKER_COUNT:-1}" ]]; then
  echo "ERROR: Expected ${ADDITIONAL_WORKER_COUNT:-1} additional compute nodes in lease, found ${ADD_COMPUTE_COUNT_LEASE}"
  exit 1
fi

# Collect and validate IPs and MACs for uniqueness and formatting
declare -a ALL_IPS=()
declare -a ALL_MACS=()

function validate_ip_mac() {
  local ip="$1"
  local mac="$2"
  local label="$3"

  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid IP format for ${label}"
    exit 1
  fi

  if [[ ! "$mac" =~ ^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$ ]]; then
    echo "ERROR: Invalid MAC format for ${label}"
    exit 1
  fi

  for existing_ip in "${ALL_IPS[@]:-}"; do
    if [[ "$existing_ip" == "$ip" ]]; then
      echo "ERROR: Duplicate IP address detected in lease entry for ${label}"
      exit 1
    fi
  done

  for existing_mac in "${ALL_MACS[@]:-}"; do
    if [[ "${existing_mac,,}" == "${mac,,}" ]]; then
      echo "ERROR: Duplicate MAC address detected in lease entry for ${label}"
      exit 1
    fi
  done

  ALL_IPS+=("$ip")
  ALL_MACS+=("$mac")
}

BOOTSTRAP_IP="$(leaseLookup 'bootstrap[0].ip')"
BOOTSTRAP_MAC="$(leaseLookup 'bootstrap[0].mac')"
validate_ip_mac "$BOOTSTRAP_IP" "$BOOTSTRAP_MAC" "bootstrap[0]"

for (( i=0; i<CP_COUNT; i++ )); do
  cp_ip="$(leaseLookup "\"control-plane\"[$i].ip")"
  cp_mac="$(leaseLookup "\"control-plane\"[$i].mac")"
  validate_ip_mac "$cp_ip" "$cp_mac" "control-plane[$i]"
done

for (( i=0; i<COMPUTE_COUNT_LEASE; i++ )); do
  comp_ip="$(leaseLookup "compute[$i].ip")"
  comp_mac="$(leaseLookup "compute[$i].mac")"
  validate_ip_mac "$comp_ip" "$comp_mac" "compute[$i]"
done

for (( i=0; i<ADD_COMPUTE_COUNT_LEASE; i++ )); do
  add_ip="$(leaseLookup "\"additional-compute\"[$i].ip")"
  add_mac="$(leaseLookup "\"additional-compute\"[$i].mac")"
  validate_ip_mac "$add_ip" "$add_mac" "additional-compute[$i]"
  add_gw="$(leaseLookup "\"additional-compute\"[$i].gateway")"
  if [[ ! "$add_gw" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid gateway format for additional-compute[$i]"
    exit 1
  fi
done

if [ "${USE_EXTERNAL_DNS:-false}" == "true" ]; then
  BASE_DOMAIN="phc-cicd.cis.ibm.net"
  CLUSTER_NAME="${LEASED_RESOURCE}"
else
  BASE_DOMAIN="${LEASED_RESOURCE}.ci"
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi
BASE_URL="${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "Creating the libvirt network.xml file..."
cat > "${SHARED_DIR}/network.xml" << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${CLUSTER_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='ocp${SUBNET}' stp='on' delay='0'/>
  <domain name='${BASE_URL}' localOnly='yes'/>
  <dns enable='yes'>
    <host ip='${BOOTSTRAP_IP}'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
EOF

for (( i=0; i<CP_COUNT; i++ )); do
  cp_ip="$(leaseLookup "\"control-plane\"[$i].ip")"
  cat >> "${SHARED_DIR}/network.xml" << EOF
    <host ip='${cp_ip}'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
EOF
done

cat >> "${SHARED_DIR}/network.xml" << EOF
  </dns>
  <ip family='ipv4' address='192.168.${SUBNET}.1' prefix='24'>
    <dhcp>
      <range start='192.168.${SUBNET}.2' end='192.168.${SUBNET}.254'/>
      <host mac='${BOOTSTRAP_MAC}' name='bootstrap.${BASE_URL}' ip='${BOOTSTRAP_IP}'/>
EOF

for (( i=0; i<CP_COUNT; i++ )); do
  cp_ip="$(leaseLookup "\"control-plane\"[$i].ip")"
  cp_mac="$(leaseLookup "\"control-plane\"[$i].mac")"
  cat >> "${SHARED_DIR}/network.xml" << EOF
      <host mac='${cp_mac}' name='control-${i}.${BASE_URL}' ip='${cp_ip}'/>
EOF
done

for (( i=0; i<COMPUTE_COUNT_LEASE; i++ )); do
  comp_ip="$(leaseLookup "compute[$i].ip")"
  comp_mac="$(leaseLookup "compute[$i].mac")"
  cat >> "${SHARED_DIR}/network.xml" << EOF
      <host mac='${comp_mac}' name='compute-${i}.${BASE_URL}' ip='${comp_ip}'/>
EOF
done

cat >> "${SHARED_DIR}/network.xml" << EOF
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.${BASE_URL}/192.168.${SUBNET}.1'/>
  </dnsmasq:options>
</network>
EOF

echo "Network XML successfully created at ${SHARED_DIR}/network.xml"

# Default UPI install-config.yaml generation
echo "Creating the install-config.yaml file..."

cat > "${SHARED_DIR}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: "${BASE_DOMAIN}"
metadata:
  name: "${CLUSTER_NAME}"
controlPlane:
  architecture: "${ARCH}"
  hyperthreading: Enabled
  name: master
  replicas: ${CONTROL_COUNT:-3}
networking:
  clusterNetwork:
  - cidr: 10.8.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: "192.168.${SUBNET}.0/24"
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
compute:
- architecture: "${ARCH}"
  hyperthreading: Enabled
  name: worker
  replicas: ${COMPUTE_COUNT:-1}
platform:
  none: {}
pullSecret: >
  $(<"${CLUSTER_PROFILE_DIR}/pull-secret")
sshKey: |
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
  echo "Adding 'fips: true' to the install config..."
  cat >> "${SHARED_DIR}/install-config.yaml" << EOF
fips: true
EOF
fi

if [ -n "${OS_IMAGE_STREAM:-}" ]; then
  echo "Adding 'osImageStream: ${OS_IMAGE_STREAM}' to the install config..."
  cat >> "${SHARED_DIR}/install-config.yaml" << EOF
osImageStream: "${OS_IMAGE_STREAM}"
EOF
fi

if [ -n "${FEATURE_SET:-}" ]; then
  echo "Adding 'featureSet: ${FEATURE_SET}' to the install config..."
  cat >> "${SHARED_DIR}/install-config.yaml" << EOF
featureSet: ${FEATURE_SET}
EOF
fi

if [ "${NODE_TUNING:-false}" = "true" ]; then
  echo "Saving node tuning yaml config..."
  cat > "${SHARED_DIR}/99-sysctl-worker.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-sysctl-worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,a2VybmVsLnNjaGVkX21pZ3JhdGlvbl9jb3N0X25zID0gMjUwMDA=
        filesystem: root
        mode: 420
        overwrite: true
        path: /etc/sysctl.conf
EOF
fi

# Chrony configuration:
# s390x control-plane and s390x workers need chrony pointed at the s390x hypervisor gateway and VPN subnets,
# whereas arm64 workers may not have an NTP server on their local gateway and can use the s390x gateway / pool NTP servers.
s390x_gateway="192.168.${SUBNET}.1"
echo "Saving chrony configuration for cluster..."
chrony_s390x_b64="$(base64 -w0 <<EOF
server ${s390x_gateway} iburst
server 192.168.1.1 iburst
server 192.168.2.1 iburst
server 192.168.3.1 iburst
server 192.168.126.1 iburst
pool 2.rhel.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
)"

echo "Saving chrony worker yaml config..."
cat > "${SHARED_DIR}/99-chrony-worker.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-chrony-worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${chrony_s390x_b64}
        filesystem: root
        mode: 420
        overwrite: true
        path: /etc/chrony.conf
EOF

echo "Saving chrony master yaml config..."
cat > "${SHARED_DIR}/99-chrony-master.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-chrony-master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${chrony_s390x_b64}
        filesystem: root
        mode: 420
        overwrite: true
        path: /etc/chrony.conf
EOF

echo "Configuration generation complete."
