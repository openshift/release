#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG=/tmp/secret/install-config.yaml

cluster_network_type=
if [[ -e "${SHARED_DIR}/cluster-network-type.txt" ]]; then
	cluster_network_type=$(<"${SHARED_DIR}/cluster-network-type.txt")
fi

cluster_variant=
if [[ -e "${SHARED_DIR}/install-config-variant.txt" ]]; then
	cluster_variant=$(<"${SHARED_DIR}/install-config-variant.txt")
fi

function has_variant() {
	regex="(^|,)$1($|,)"
	if [[ $cluster_variant =~ $regex ]]; then
		return 0
	fi
	return 1
}

if has_variant "ovn"; then
	cluster_network_type=OVNKubernetes
fi
if has_variant "ipv6"; then
	export OPENSHIFT_INSTALL_AZURE_EMULATE_SINGLESTACK_IPV6=true
	cat >> "${CONFIG}" <<-EOF
	networking:
	  networkType: OVNKubernetes
	  machineNetwork:
	    - cidr: 10.0.0.0/16
	    - cidr: fd00::/48
	  clusterNetwork:
	    - cidr: fd01::/48
	      hostPrefix: 64
	  serviceNetwork:
	    - fd02::/112
	EOF
elif [[ -n "${cluster_network_type}" ]]; then
	cat >> "${CONFIG}" <<-EOF
	networking:
	  networkType: ${cluster_network_type}
	EOF
fi
