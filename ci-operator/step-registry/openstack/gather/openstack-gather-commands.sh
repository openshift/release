#!/usr/bin/env bash

set -o nounset

cd /tmp || exit

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
CREATE_FIPS=1

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
    CREATE_FIPS=0
fi

if [[ "$CONFIG_TYPE" == *"proxy"* ]]; then
    BASTION_FIP=$(<"${SHARED_DIR}/BASTION_FIP")
    BASTION_USER=$(<"${SHARED_DIR}/BASTION_USER")
fi

collect_bootstrap_logs() {
	if [ "$CLUSTER_NAME" != "" ]; then
		declare -a GATHER_BOOTSTRAP_ARGS
		declare -a FIPS
		IP=

		BOOTSTRAP_NODE=$(openstack server list --format value -c Name | awk "/${CLUSTER_NAME}-.{5}-bootstrap/ {print}")
		if [ "$BOOTSTRAP_NODE" != "" ]; then
			echo "Collecting bootstrap logs..."
			CLUSTER_ID=${BOOTSTRAP_NODE%-bootstrap}
			openstack security group rule create "${CLUSTER_ID}-master" --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0
			if [[ $CREATE_FIPS == 1 ]]; then
				IP=$(openstack floating ip list --port "${CLUSTER_ID}-bootstrap-port" -c "Floating IP Address" -f value)
				if [[ ${IP} == "" ]]; then
					IP=$(openstack floating ip create "$OPENSTACK_EXTERNAL_NETWORK" --description "${CLUSTER_ID}-bootstrap" --format value --column floating_ip_address)
				fi
				FIPS+=("${IP}")
				openstack server add floating ip "${CLUSTER_ID}-bootstrap" "${IP}"
			else
				ADDRESSES=$(openstack server show "${BOOTSTRAP_NODE}" --column addresses --format json)
				IP=$(echo "${ADDRESSES}" | jq -r 'if .addresses|type == "object" then .addresses[][0] else .addresses|split("=")[1]|split(",")[0] end')
			fi
			GATHER_BOOTSTRAP_ARGS+=('--bootstrap' "${IP}")

			for idx in 0 1 2; do
				if openstack server show "${CLUSTER_ID}-master-${idx}" &> /dev/null; then
					if [[ $CREATE_FIPS == 1 ]]; then
						IP=$(openstack floating ip create "$OPENSTACK_EXTERNAL_NETWORK" --description "${CLUSTER_ID}-master-${idx}" --format value --column floating_ip_address)
						FIPS+=("${IP}")
						openstack server add floating ip "${CLUSTER_ID}-master-${idx}" "${IP}"
					else
						ADDRESSES=$(openstack server show "${CLUSTER_ID}-master-${idx}" --column addresses --format json)
						IP=$(echo "${ADDRESSES}" | jq -r 'if .addresses|type == "object" then .addresses[][0] else .addresses|split("=")[1]|split(",")[0] end')
					fi
					GATHER_BOOTSTRAP_ARGS+=('--master' "${IP}")
				fi
			done
			# Ideally this would be removed once the openshift-install gather bootstrap starts supporting proxy https://issues.redhat.com/browse/CORS-2367
			SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
    			if test -f "${SHARED_DIR}/squid-credentials.txt"; then
    			    echo "This job uses a proxy but without a bastion, `openshift-install gather` is not supported yet, see CORS-2367"
			else
                            if [[ "$CONFIG_TYPE" == *"proxy"* ]]; then
			    	# configure the local container environment to have the correct SSH configuration
			    	if ! whoami &> /dev/null; then
			    		if [[ -w /etc/passwd ]]; then
			    			echo "${BASTION_USER}:x:$(id -u):0:${BASTION_USER} user:${HOME}:/sbin/nologin" >> /etc/passwd
			    		fi
			    	fi
			    	SSH_ARGS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -i $SSH_PRIV_KEY_PATH"
			    	SSH_CMD="ssh $SSH_ARGS $BASTION_USER@$BASTION_FIP"
			    	SCP_CMD="scp $SSH_ARGS"
			    	if ! $SSH_CMD uname -a; then
			    		echo "ERROR: Bastion proxy is not reachable via $BASTION_FIP"
			    		exit 1
			    	fi
			    	echo "Moving credentials and openshift binary to Bastion Proxy"
			    	$SCP_CMD "$SSH_PRIV_KEY_PATH" /bin/openshift-install "${BASTION_USER}@${BASTION_FIP}:/tmp"
			    	echo "Gathering bootstrap logs from Bastion Proxy"
			    	$SSH_CMD bash - << EOF
/tmp/openshift-install gather bootstrap --key /tmp/ssh-privatekey ${GATHER_BOOTSTRAP_ARGS[@]}
EOF
			    	echo "Copying logs"
			    	$SCP_CMD "${BASTION_USER}@${BASTION_FIP}:/home/${BASTION_USER}/log-bundle-*.tar.gz" "${SHARED_DIR}/"
			    else
			    	openshift-install gather bootstrap --key "${SSH_PRIV_KEY_PATH}" "${GATHER_BOOTSTRAP_ARGS[@]}"
			    	cp log-bundle-*.tar.gz "${ARTIFACT_DIR}"
			    	echo "${FIPS[@]}" | xargs --no-run-if-empty openstack floating ip delete
			    fi
			fi
		fi
	fi
}

export ARTIFACT_DIR_JSON="${ARTIFACT_DIR}/json"
mkdir -p "$ARTIFACT_DIR_JSON"

openstack server list --name "${CLUSTER_NAME}" -f json > "${ARTIFACT_DIR_JSON}/openstack_server_list.json"

for server in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_server_list.json"); do
	openstack server show "$server" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_server_show.json"

openstack volume list -f json \
	| jq --arg CLUSTER_NAME "$CLUSTER_NAME" 'map(select(.Name | test($CLUSTER_NAME)))' \
	> "${ARTIFACT_DIR_JSON}/openstack_volume_list.json"

for volume in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_volume_list.json"); do
	openstack volume show "$volume" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_volume_show.json"

openstack port list -f json \
        | jq --arg CLUSTER_NAME "$CLUSTER_NAME" 'map(select(.Name | test($CLUSTER_NAME)))' \
        > "${ARTIFACT_DIR_JSON}/openstack_port_list.json"

for port in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_port_list.json"); do
	openstack port show "$port" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_port_show.json"

openstack subnet list -f json \
        | jq --arg CLUSTER_NAME "$CLUSTER_NAME" 'map(select(.Name | test($CLUSTER_NAME)))' \
        > "${ARTIFACT_DIR_JSON}/openstack_subnet_list.json"

for port in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_subnet_list.json"); do
        openstack subnet show "$port" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_subnet_show.json"

openstack floating ip list --long -f json \
        | jq --arg CLUSTER_NAME "$CLUSTER_NAME" 'map(select(.Description | test($CLUSTER_NAME)))' \
        > "${ARTIFACT_DIR_JSON}/openstack_fip_list.json"

for fip in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_fip_list.json"); do
        openstack floating ip show "$fip" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_fip_show.json"

mkdir -p "${ARTIFACT_DIR}/nodes"

openstack server list --name "$CLUSTER_NAME" > "${ARTIFACT_DIR}/openstack_nodes.log"
for server in $(openstack server list --name "$CLUSTER_NAME" -c Name -f value | sort); do
	echo -e "\n$ openstack server show $server"   >> "${ARTIFACT_DIR}/openstack_nodes.log"
	openstack server show "$server"               >> "${ARTIFACT_DIR}/openstack_nodes.log"

	openstack console log show "$server"          &> "${ARTIFACT_DIR}/nodes/console_${server}.log"
done

openstack volume list | grep "$CLUSTER_NAME" > "${ARTIFACT_DIR}/openstack_volumes.log" || true
for volume in $(openstack volume list -c Name -f value | { grep "$CLUSTER_NAME" || true; } | sort); do
	echo -e "\n$ openstack volume show $volume" >> "${ARTIFACT_DIR}/openstack_volumes.log"
	openstack volume show "$volume"             >> "${ARTIFACT_DIR}/openstack_volumes.log"
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
