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

if [ "${USE_EXTERNAL_DNS:-false}" == "true" ]; then
  BASE_DOMAIN="phc-cicd.cis.ibm.net"
  CLUSTER_NAME="${LEASED_RESOURCE}"
else
  BASE_DOMAIN="${LEASED_RESOURCE}.ci"
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi
BASE_URL="${CLUSTER_NAME}.${BASE_DOMAIN}"

CONTROL_COUNT="${CONTROL_COUNT:-3}"
COMPUTE_COUNT="${COMPUTE_COUNT:-2}"
ARBITER_COUNT="${ARBITER_COUNT:-0}"

echo "Creating the libvirt network.xml file..."

# This network xml forces the IP address of the rendezvous host to use the bootstrap IP.
# We do this so that we can debug agent-based clusters by taking advantage of the open
# SSH tunnel we created to pull debug logs for our libvirt IPI and UPI default workflows.
if [ "$INSTALLER_TYPE" == "agent" ]; then
  # TNA: two masters + one arbiter (optional workers). Arbiter reuses control-plane lease slots
  # after the masters. Agent DHCP shifts IPs so control-0 keeps the bootstrap address.
  if [[ "${ARBITER_COUNT}" -gt 0 ]]; then
    if [[ "${CONTROL_COUNT}" -lt 2 ]]; then
      echo "ERROR: ARBITER_COUNT=${ARBITER_COUNT} requires CONTROL_COUNT>=2 (got ${CONTROL_COUNT})" >&2
      exit 1
    fi
    {
      cat << EOF
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
EOF
      # Master IPs after agent remap: control-0 -> bootstrap, control-i -> control-plane[i-1]
      for (( i=1; i<CONTROL_COUNT; i++ )); do
        prev=$((i - 1))
        cat << EOF
    <host ip='$(leaseLookup "\"control-plane\"[${prev}].ip")'>
      <hostname>api.${BASE_URL}</hostname>
      <hostname>api-int.${BASE_URL}</hostname>
    </host>
EOF
      done
      cat << EOF
  </dns>
  <ip family='ipv4' address='192.168.$(leaseLookup "subnet").1' prefix='24'>
    <dhcp>
      <range start='192.168.$(leaseLookup "subnet").2' end='192.168.$(leaseLookup "subnet").254'/>
EOF
      for (( i=0; i<CONTROL_COUNT; i++ )); do
        if [[ "${i}" -eq 0 ]]; then
          host_ip="$(leaseLookup 'bootstrap[0].ip')"
        else
          prev=$((i - 1))
          host_ip="$(leaseLookup "\"control-plane\"[${prev}].ip")"
        fi
        cat << EOF
      <host mac='$(leaseLookup "\"control-plane\"[${i}].mac")' name='control-${i}.${BASE_URL}' ip='${host_ip}'/>
EOF
      done
      for (( i=0; i<ARBITER_COUNT; i++ )); do
        lease_idx=$((CONTROL_COUNT + i))
        prev=$((lease_idx - 1))
        cat << EOF
      <host mac='$(leaseLookup "\"control-plane\"[${lease_idx}].mac")' name='arbiter-${i}.${BASE_URL}' ip='$(leaseLookup "\"control-plane\"[${prev}].ip")'/>
EOF
      done
      for (( i=0; i<COMPUTE_COUNT; i++ )); do
        cat << EOF
      <host mac='$(leaseLookup "compute[${i}].mac")' name='compute-${i}.${BASE_URL}' ip='$(leaseLookup "compute[${i}].ip")'/>
EOF
      done
      cat << EOF
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.${BASE_URL}/192.168.$(leaseLookup "subnet").1'/>
  </dnsmasq:options>
</network>
EOF
    } >> "${SHARED_DIR}/network.xml"
  # SNO: one rendezvous host (control-0 at bootstrap IP). HA agent jobs keep the 3+2 template below.
  elif [ "${CONTROL_COUNT}" = "1" ] && [ "${COMPUTE_COUNT}" = "0" ]; then
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
  </dns>
  <ip family='ipv4' address='192.168.$(leaseLookup "subnet").1' prefix='24'>
    <dhcp>
      <range start='192.168.$(leaseLookup "subnet").2' end='192.168.$(leaseLookup "subnet").254'/>
      <host mac='$(leaseLookup '"control-plane"[0].mac')' name='control-0.${BASE_URL}' ip='$(leaseLookup 'bootstrap[0].ip')'/>
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
  fi
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
