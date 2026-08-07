#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# Only run for singlestackv6 config
if [[ "$CONFIG_TYPE" != *"singlestackv6"* ]]; then
    info "Skipping IPv6 clouds.yaml configuration (CONFIG_TYPE=${CONFIG_TYPE})"
    exit 0
fi

# Create openstack-ipv6 cloud entry (required by install-config for singlestackv6)
# This is just a copy of the original cloud - the squid proxy handles the routing
yq --yml-output ".clouds[\"${OS_CLOUD}-ipv6\"] = .clouds[\"${OS_CLOUD}\"]" "${SHARED_DIR}/clouds.yaml" > "${SHARED_DIR}/clouds-ipv6.yaml"
mv "${SHARED_DIR}/clouds-ipv6.yaml" "${SHARED_DIR}/clouds.yaml"
info "Created ${OS_CLOUD}-ipv6 cloud entry in clouds.yaml"

# Get the mirror VM's IP for the squid proxy
if [[ -f "${SHARED_DIR}/OPENSTACK_MITM_PROXY_IP" ]]; then
	MITM_PROXY_IP=$(<"${SHARED_DIR}/OPENSTACK_MITM_PROXY_IP")
	info "Using squid proxy on mirror VM: ${MITM_PROXY_IP}"
else
	info "ERROR: OPENSTACK_MITM_PROXY_IP file not found"
	info "The mirror VM should have been provisioned before this step"
	exit 1
fi

# Configure HTTP/HTTPS proxy environment variables
# Squid is running on port 13001 and will tunnel all OpenStack API traffic
info "Configuring HTTP proxy: http://${MITM_PROXY_IP}:13001"

cat > "${SHARED_DIR}/proxy-conf.sh" << PROXY_CONF
# Squid proxy configuration for OpenStack API access
export HTTP_PROXY="http://${MITM_PROXY_IP}:13001"
export HTTPS_PROXY="http://${MITM_PROXY_IP}:13001"
export NO_PROXY="localhost,127.0.0.1"
PROXY_CONF

info "Proxy configuration written to ${SHARED_DIR}/proxy-conf.sh"
