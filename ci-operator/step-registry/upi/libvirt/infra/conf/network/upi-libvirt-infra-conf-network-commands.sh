#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Two-cluster support: CLUSTER_ROLE=infra redirects to the infra lease.
# Files are written with an "infra-" prefix so they stay flat in SHARED_DIR —
# Kubernetes secrets don't support subdirectories; any subdir is silently
# dropped by the sidecar when it serialises the shared dir between steps.
if [[ "${CLUSTER_ROLE:-mgmt}" == "infra" ]]; then
  LEASED_RESOURCE="${LEASED_RESOURCE_INFRA}"
  INFRA_PREFIX="infra-"
else
  INFRA_PREFIX=""
fi

# Scan for yq-v4
if ! command -v yq-v4 &> /dev/null
then
    echo "yq-v4 could not be found"
    exit 1
fi

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${1} in lease config"
    exit 1
  fi
  echo "$lookup"
}

if [ "${USE_EXTERNAL_DNS:-false}" == "true" ]; then
  BASE_DOMAIN="phc-cicd.cis.ibm.net"
  CLUSTER_NAME="${LEASED_RESOURCE}"
else
  BASE_DOMAIN="${LEASED_RESOURCE}.ci"
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi
BASE_URL="${CLUSTER_NAME}.${BASE_DOMAIN}"

# Determine which subnet to use for the infra cluster's libvirt bridge.
# Priority:
#   1. MGMT_SUBNET_OVERRIDE env var — explicit caller override.
#   2. $SHARED_DIR/MGMT_SUBNET — written by upi-conf-libvirt-network-commands.sh
#      (the mgmt cluster's network conf step) which runs before this step and
#      has the mgmt LEASED_RESOURCE in scope.
#   3. Infra lease's own subnet — fallback for standalone runs.
if [[ -n "${MGMT_SUBNET_OVERRIDE:-}" ]]; then
  NET_SUBNET="${MGMT_SUBNET_OVERRIDE}"
  echo "Using MGMT_SUBNET_OVERRIDE=${NET_SUBNET}"
elif [[ -f "${SHARED_DIR}/MGMT_SUBNET" ]]; then
  NET_SUBNET="$(cat "${SHARED_DIR}/MGMT_SUBNET")"
  echo "Using mgmt subnet from SHARED_DIR/MGMT_SUBNET: ${NET_SUBNET}"
else
  NET_SUBNET="$(leaseLookup 'subnet')"
  echo "No MGMT_SUBNET file found, using infra lease subnet: ${NET_SUBNET}"
fi
CP0_IP="192.168.${NET_SUBNET}.61"
CP1_IP="192.168.${NET_SUBNET}.62"
CP2_IP="192.168.${NET_SUBNET}.63"
echo "Infra cluster will use bridge ocp${NET_SUBNET}, control-plane IPs ${CP0_IP}-${CP2_IP}"

echo "Creating the libvirt network.xml file..."

# This network xml forces the IP address of the rendezvous host to use the bootstrap IP.
# We do this so that we can debug agent-based clusters by taking advantage of the open
# SSH tunnel we created to pull debug logs for our libvirt IPI and UPI default workflows.
if [ "$INSTALLER_TYPE" == "agent" ]; then
  cat >> "${SHARED_DIR}/${INFRA_PREFIX}network.xml" << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${CLUSTER_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='ocp${NET_SUBNET}' stp='on' delay='0'/>
  <domain name='${BASE_URL}' localOnly='yes'/>
  <dns enable='yes'>
    <host ip='$(leaseLookup '"bootstrap"[0].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='${CP0_IP}'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='${CP1_IP}'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
  </dns>
  <ip family='ipv4' address='192.168.${NET_SUBNET}.1' prefix='24'>
    <dhcp>
      <range start='192.168.${NET_SUBNET}.2' end='192.168.${NET_SUBNET}.254'/>
      <host mac='$(leaseLookup '"control-plane"[0].mac')' name='control-0.${BASE_URL}' ip='$(leaseLookup 'bootstrap[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[1].mac')' name='control-1.${BASE_URL}' ip='${CP0_IP}'/>
      <host mac='$(leaseLookup '"control-plane"[2].mac')' name='control-2.${BASE_URL}' ip='${CP1_IP}'/>
      <host mac='$(leaseLookup 'compute[0].mac')' name='compute-0.${BASE_URL}' ip='$(leaseLookup 'compute[0].ip')'/>
      <host mac='$(leaseLookup 'compute[1].mac')' name='compute-1.${BASE_URL}' ip='$(leaseLookup 'compute[1].ip')'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.${BASE_URL}/192.168.${NET_SUBNET}.1'/>
  </dnsmasq:options>
</network>
EOF

else
  cat >> "${SHARED_DIR}/${INFRA_PREFIX}network.xml" << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${CLUSTER_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='ocp${NET_SUBNET}' stp='on' delay='0'/>
  <domain name='${BASE_URL}' localOnly='yes'/>
  <dns enable='yes'>
    <host ip='$(leaseLookup '"bootstrap"[0].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='${CP0_IP}'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='${CP1_IP}'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='${CP2_IP}'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
  </dns>
  <ip family='ipv4' address='192.168.${NET_SUBNET}.1' prefix='24'>
    <dhcp>
      <range start='192.168.${NET_SUBNET}.2' end='192.168.${NET_SUBNET}.254'/>
      <host mac='$(leaseLookup 'bootstrap[0].mac')' name='bootstrap.${BASE_URL}' ip='$(leaseLookup 'bootstrap[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[0].mac')' name='control-0.${BASE_URL}' ip='${CP0_IP}'/>
      <host mac='$(leaseLookup '"control-plane"[1].mac')' name='control-1.${BASE_URL}' ip='${CP1_IP}'/>
      <host mac='$(leaseLookup '"control-plane"[2].mac')' name='control-2.${BASE_URL}' ip='${CP2_IP}'/>
      <host mac='$(leaseLookup 'compute[0].mac')' name='compute-0.${BASE_URL}' ip='$(leaseLookup 'compute[0].ip')'/>
      <host mac='$(leaseLookup 'compute[1].mac')' name='compute-1.${BASE_URL}' ip='$(leaseLookup 'compute[1].ip')'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.${BASE_URL}/192.168.${NET_SUBNET}.1'/>
  </dnsmasq:options>
</network>
EOF
fi

cat "${SHARED_DIR}/${INFRA_PREFIX}network.xml"
