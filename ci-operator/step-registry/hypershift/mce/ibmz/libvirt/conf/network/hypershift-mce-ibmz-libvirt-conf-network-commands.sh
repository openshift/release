#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common/hypershift-mce-ibmz-libvirt-common.sh
source "${SCRIPT_DIR}/../../common/hypershift-mce-ibmz-libvirt-common.sh"

if ! command -v yq-v4 &> /dev/null; then
  echo "yq-v4 could not be found"
  exit 1
fi

if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
cluster_libvirt_init
leaseLookup() { cluster_libvirt_lease_lookup "$1"; }

echo "Creating network.xml for ${CLUSTER_ROLE} cluster (${CLUSTER_NAME})..."

if [[ "$INSTALLER_TYPE" == "agent" ]]; then
  cat >> "${CLUSTER_DIR}/network.xml" << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${CLUSTER_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='ocp$(leaseLookup "subnet")' stp='on' delay='0'/>
  <domain name='${CLUSTER_NAME}.${BASE_DOMAIN}' localOnly='yes'/>
  <dns enable='yes'>
    <host ip='$(leaseLookup '"bootstrap"[0].ip')'>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[0].ip')'>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[1].ip')'>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
  </dns>
  <ip family='ipv4' address='192.168.$(leaseLookup "subnet").1' prefix='24'>
    <dhcp>
      <range start='192.168.$(leaseLookup "subnet").2' end='192.168.$(leaseLookup "subnet").254'/>
      <host mac='$(leaseLookup '"control-plane"[0].mac')' name='control-0.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup 'bootstrap[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[1].mac')' name='control-1.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup '"control-plane"[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[2].mac')' name='control-2.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup '"control-plane"[1].ip')'/>
      <host mac='$(leaseLookup 'compute[0].mac')' name='compute-0.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup 'compute[0].ip')'/>
      <host mac='$(leaseLookup 'compute[1].mac')' name='compute-1.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup 'compute[1].ip')'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/192.168.$(leaseLookup "subnet").1'/>
  </dnsmasq:options>
</network>
EOF
else
  cat >> "${CLUSTER_DIR}/network.xml" << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${CLUSTER_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='ocp$(leaseLookup "subnet")' stp='on' delay='0'/>
  <domain name='${CLUSTER_NAME}.${BASE_DOMAIN}' localOnly='yes'/>
  <dns enable='yes'>
    <host ip='$(leaseLookup '"bootstrap"[0].ip')'>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[0].ip')'>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[1].ip')'>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
    <host ip='$(leaseLookup '"control-plane"[2].ip')'>
      <hostname>api.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
    </host>
  </dns>
  <ip family='ipv4' address='192.168.$(leaseLookup "subnet").1' prefix='24'>
    <dhcp>
      <range start='192.168.$(leaseLookup "subnet").2' end='192.168.$(leaseLookup "subnet").254'/>
      <host mac='$(leaseLookup 'bootstrap[0].mac')' name='bootstrap.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup 'bootstrap[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[0].mac')' name='control-0.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup '"control-plane"[0].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[1].mac')' name='control-1.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup '"control-plane"[1].ip')'/>
      <host mac='$(leaseLookup '"control-plane"[2].mac')' name='control-2.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup '"control-plane"[2].ip')'/>
      <host mac='$(leaseLookup 'compute[0].mac')' name='compute-0.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup 'compute[0].ip')'/>
      <host mac='$(leaseLookup 'compute[1].mac')' name='compute-1.${CLUSTER_NAME}.${BASE_DOMAIN}' ip='$(leaseLookup 'compute[1].ip')'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/192.168.$(leaseLookup "subnet").1'/>
  </dnsmasq:options>
</network>
EOF
fi

cat "${CLUSTER_DIR}/network.xml"
