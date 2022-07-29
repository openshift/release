#!/usr/bin/env bash

set -o nounset
set -x

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")

collect_bootstrap_logs() {
	if [ "$CLUSTER_NAME" != "" ]; then
		declare -a GATHER_BOOTSTRAP_ARGS
		declare -a FIPS
		
		BOOTSTRAP_NODE=$(openstack server list --format value -c Name | awk "/${CLUSTER_NAME}-.{5}-bootstrap/ {print}")
		if [ "$BOOTSTRAP_NODE" != "" ]; then
			echo "Collecting bootstrap logs..."
			CLUSTER_ID=${BOOTSTRAP_NODE%-bootstrap}
			openstack security group rule create ${CLUSTER_ID}-master --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0
			FIP=$(openstack floating ip create "$OPENSTACK_EXTERNAL_NETWORK" --description "${CLUSTER_ID}-bootstrap" --format value --column floating_ip_address)
			FIPS+=("${FIP}")
			openstack server add floating ip ${CLUSTER_ID}-bootstrap ${FIP}
			GATHER_BOOTSTRAP_ARGS+=('--bootstrap' "${FIP}")
			
			for idx in 0 1 2; do
				if openstack server show ${CLUSTER_ID}-master-${idx} &> /dev/null; then
					FIP=$(openstack floating ip create "$OPENSTACK_EXTERNAL_NETWORK" --description "${CLUSTER_ID}-master-${idx}" --format value --column floating_ip_address)
					FIPS+=("${FIP}")
					openstack server add floating ip ${CLUSTER_ID}-master-${idx} ${FIP}
					GATHER_BOOTSTRAP_ARGS+=('--master' "${FIP}")
				fi
			done
			
			SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
			openshift-install gather bootstrap --key "${SSH_PRIV_KEY_PATH}" "${GATHER_BOOTSTRAP_ARGS[@]}"
			cp log-bundle-*.tar.gz "${ARTIFACT_DIR}"
			openstack floating ip delete "${FIPS[@]}"
		fi
	fi
}

mkdir -p "${ARTIFACT_DIR}/nodes"

openstack server list --name "$CLUSTER_NAME" > "${ARTIFACT_DIR}/openstack_nodes.log"
for server in $(openstack server list --name "$CLUSTER_NAME" -c Name -f value | sort); do
	echo -e "\n$ openstack server show $server"   >> "${ARTIFACT_DIR}/openstack_nodes.log"
	openstack server show "$server"               >> "${ARTIFACT_DIR}/openstack_nodes.log"

	openstack console log show "$server"          &> "${ARTIFACT_DIR}/nodes/console_${server}.log"
done

openstack port list | grep "$CLUSTER_NAME" > "${ARTIFACT_DIR}/openstack_ports.log" || true
for port in $(openstack port list -c Name -f value | { grep "$CLUSTER_NAME" || true; } | sort); do
	echo -e "\n$ openstack port show $port" >> "${ARTIFACT_DIR}/openstack_ports.log"
	openstack port show "$port"               >> "${ARTIFACT_DIR}/openstack_ports.log"
done

openstack subnet list | grep "$CLUSTER_NAME" > "${ARTIFACT_DIR}/openstack_subnets.log" || true
for subnet in $(openstack subnet list -c Name -f value | { grep "$CLUSTER_NAME" || true; } | sort); do
	echo -e "\n$ openstack subnet show $subnet" >> "${ARTIFACT_DIR}/openstack_subnets.log"
	openstack subnet show "$subnet"             >> "${ARTIFACT_DIR}/openstack_subnets.log"
done

collect_bootstrap_logs
