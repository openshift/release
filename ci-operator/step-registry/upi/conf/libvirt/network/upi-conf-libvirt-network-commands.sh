#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

BASE_DOMAIN="${LEASED_RESOURCE}.ci"
CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
BASE_URL="${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "Creating the libvirt network.xml file..."

# This network xml forces the IP address of the rendezvous host to use the bootstrap IP.
# We do this so that we can debug agent-based clusters by taking advantage of the open
# SSH tunnel we created to pull debug logs for our libvirt IPI and UPI default workflows.
if [ "$INSTALLER_TYPE" == "agent" ]; then
  cat >> "${SHARED_DIR}/network.xml" << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${CLUSTER_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='ocp$(leaseLookup "subnet")' stp='on' delay='0'/>
  <domain name='${BASE_URL}' localOnly='yes'/>
  <dns enable='yes'>
    <host ip='$(leaseLookup '"bootstrap"[0].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[0].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[1].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
  </dns>
  <ip family='ipv4' address='192.168.$(leaseLookup "subnet").1' prefix='24'>
    <dhcp>
      <range start='192.168.$(leaseLookup "subnet").2' end='192.168.$(leaseLookup "subnet").254'/>
      <host mac='$(leaseLookup '"control-plane"[0].mac')' name='control-0.${BASE_URL}' ip='$(leaseLookup 'bootstrap[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[1].mac')' name='control-1.${BASE_URL}' ip='$(leaseLookup '"control-plane"[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[2].mac')' name='control-2.${BASE_URL}' ip='$(leaseLookup '"control-plane"[1].ip')'/>
      <host mac='$(leaseLookup 'compute[0].mac')' name='compute-0.${BASE_URL}' ip='$(leaseLookup 'compute[0].ip')'/>
      <host mac='$(leaseLookup 'compute[1].mac')' name='compute-1.${BASE_URL}' ip='$(leaseLookup 'compute[1].ip')'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.${BASE_URL}/192.168.$(leaseLookup "subnet").1'/>
  </dnsmasq:options>
</network>
EOF

else
  cat >> "${SHARED_DIR}/network.xml" << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${CLUSTER_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='ocp$(leaseLookup "subnet")' stp='on' delay='0'/>
  <domain name='${BASE_URL}' localOnly='yes'/>
  <dns enable='yes'>
    <host ip='$(leaseLookup '"bootstrap"[0].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[0].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[1].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[2].ip')'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
  </dns>
  <ip family='ipv4' address='192.168.$(leaseLookup "subnet").1' prefix='24'>
    <dhcp>
      <range start='192.168.$(leaseLookup "subnet").2' end='192.168.$(leaseLookup "subnet").254'/>
      <host mac='$(leaseLookup 'bootstrap[0].mac')' name='bootstrap.${BASE_URL}' ip='$(leaseLookup 'bootstrap[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[0].mac')' name='control-0.${BASE_URL}' ip='$(leaseLookup '"control-plane"[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[1].mac')' name='control-1.${BASE_URL}' ip='$(leaseLookup '"control-plane"[1].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[2].mac')' name='control-2.${BASE_URL}' ip='$(leaseLookup '"control-plane"[2].ip')'/>
      <host mac='$(leaseLookup 'compute[0].mac')' name='compute-0.${BASE_URL}' ip='$(leaseLookup 'compute[0].ip')'/>
      <host mac='$(leaseLookup 'compute[1].mac')' name='compute-1.${BASE_URL}' ip='$(leaseLookup 'compute[1].ip')'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.${BASE_URL}/192.168.$(leaseLookup "subnet").1'/>
  </dnsmasq:options>
</network>
EOF
fi

cat "${SHARED_DIR}/network.xml"