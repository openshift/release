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
mkdir -p "${ARTIFACT_DIR}/nodes"

# for each resource we gather both JSON-formatted output and standard table
# output

# servers

openstack server list --name "${CLUSTER_NAME}" -f json > "${ARTIFACT_DIR_JSON}/openstack_server_list.json"

for server in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_server_list.json"); do
	openstack server show "$server" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_server_show.json"

touch "${ARTIFACT_DIR}/openstack_nodes.log"
for server in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_server_list.json"); do
	echo -e "\n$ openstack server show $server"   &>> "${ARTIFACT_DIR}/openstack_nodes.log"
	openstack server show "$server"               &>> "${ARTIFACT_DIR}/openstack_nodes.log"
	openstack console log show "$server"          &>> "${ARTIFACT_DIR}/nodes/console_${server}.log"
done

# volumes

openstack volume list -f json \
	| jq --arg CLUSTER_NAME "$CLUSTER_NAME" 'map(select(.Name | test($CLUSTER_NAME)))' \
	> "${ARTIFACT_DIR_JSON}/openstack_volume_list.json"

for volume in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_volume_list.json"); do
	openstack volume show "$volume" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_volume_show.json"

touch "${ARTIFACT_DIR}/openstack_volumes.log"
for volume in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_volume_list.json"); do
	echo -e "\n$ openstack volume show $volume" &>> "${ARTIFACT_DIR}/openstack_volumes.log"
	openstack volume show "$volume"             &>> "${ARTIFACT_DIR}/openstack_volumes.log"
done

# ports

openstack port list -f json \
    | jq --arg CLUSTER_NAME "$CLUSTER_NAME" 'map(select(.Name | test($CLUSTER_NAME)))' \
    > "${ARTIFACT_DIR_JSON}/openstack_port_list.json"

for port in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_port_list.json"); do
	openstack port show "$port" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_port_show.json"

touch "${ARTIFACT_DIR}/openstack_ports.log"
for port in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_port_list.json"); do
	echo -e "\n$ openstack port show $port" &>> "${ARTIFACT_DIR}/openstack_ports.log"
	openstack port show "$port"             &>> "${ARTIFACT_DIR}/openstack_ports.log"
done

# subnets

openstack subnet list -f json \
    | jq --arg CLUSTER_NAME "$CLUSTER_NAME" 'map(select(.Name | test($CLUSTER_NAME)))' \
    > "${ARTIFACT_DIR_JSON}/openstack_subnet_list.json"

for subnet in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_subnet_list.json"); do
	openstack subnet show "$subnet" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_subnet_show.json"

touch "${ARTIFACT_DIR}/openstack_subnets.log"
for subnet in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_subnet_list.json"); do
	echo -e "\n$ openstack subnet show $subnet" &>> "${ARTIFACT_DIR}/openstack_subnets.log"
	openstack subnet show "$subnet"             &>> "${ARTIFACT_DIR}/openstack_subnets.log"
done

# floating IPs

openstack floating ip list --long -f json \
    | jq --arg CLUSTER_NAME "$CLUSTER_NAME" 'map(select(.Description | test($CLUSTER_NAME)))' \
    > "${ARTIFACT_DIR_JSON}/openstack_fip_list.json"

for fip in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_fip_list.json"); do
	openstack floating ip show "$fip" -f json
done | jq --slurp '.' > "${ARTIFACT_DIR_JSON}/openstack_fip_show.json"

touch "${ARTIFACT_DIR}/openstack_fips.log"
for fip in $(jq -r '.[].ID' "${ARTIFACT_DIR_JSON}/openstack_fip_list.json"); do
	echo -e "\n$ openstack floating ip show $fip" &>> "${ARTIFACT_DIR}/openstack_fips.log"
	openstack floating ip show "$fip"             &>> "${ARTIFACT_DIR}/openstack_fips.log"
done


# Temporary debug for Keystone reachability from in-cluster CAPO on proxy/BYON
# topologies (e.g. proxy-externallb after UserManaged is accepted). Best-effort
# only: never fail gather if the API is down or resources are missing.
# Runs before collect_bootstrap_logs so bastion SSH failures cannot skip it.
collect_capi_proxy_debug() {
	local kubeconfig="${SHARED_DIR}/kubeconfig"
	local out="${ARTIFACT_DIR}/capi-proxy-keystone-debug.log"

	if [[ ! -f "${kubeconfig}" ]]; then
		echo "Skipping CAPO/proxy debug: no kubeconfig in SHARED_DIR"
		return 0
	fi

	export KUBECONFIG="${kubeconfig}"

	# Resolve pod name outside the piped brace group (local is invalid in a subshell).
	local pod
	pod="$(oc -n openshift-cluster-api-operator get pods -l k8s-app=capi-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

	{
		echo "===== CAPO / proxy / Keystone debug ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ====="
		echo "CONFIG_TYPE=${CONFIG_TYPE:-}"
		echo

		echo "----- Proxy CR (cluster) -----"
		oc get proxy cluster -o yaml 2>&1 || true
		echo

		echo "----- Proxy env injected into capi-operator Deployment -----"
		oc -n openshift-cluster-api-operator get deploy capi-operator \
			-o jsonpath='{range .spec.template.spec.containers[?(@.name=="capi-operator")].env[*]}{.name}={.value}{"\n"}{end}' 2>&1 || true
		echo
		echo "(full env list including valueFrom):"
		oc -n openshift-cluster-api-operator get deploy capi-operator \
			-o jsonpath='{.spec.template.spec.containers[?(@.name=="capi-operator")].env}' 2>&1 | python3 -m json.tool 2>&1 || true
		echo

		echo "----- Running capi-operator pod env (HTTP(S)_PROXY / NO_PROXY) -----"
		if [[ -n "${pod}" ]]; then
			echo "pod=${pod}"
			oc -n openshift-cluster-api-operator exec "${pod}" -c capi-operator -- \
				/bin/sh -c 'env | grep -E "^(HTTP|HTTPS|NO|http|https|no)_?PROXY=" | sort' 2>&1 || true
		else
			echo "No capi-operator pod found"
		fi
		echo

		echo "----- openstack-cloud-credentials secret keys (sizes only) -----"
		oc -n openshift-cluster-api get secret openstack-cloud-credentials -o json 2>&1 \
			| python3 -c '
import sys, json, base64
try:
    d = json.load(sys.stdin)
    data = d.get("data") or {}
    for k, v in sorted(data.items()):
        raw = base64.b64decode(v)
        print(f"{k}: {len(raw)} bytes")
        if k == "clouds.yaml":
            # redact secrets; show auth_url only
            text = raw.decode("utf-8", errors="replace")
            for line in text.splitlines():
                if "auth_url" in line or "cloud:" in line or line.strip().startswith("clouds:"):
                    print(f"  {line}")
        if k == "cacert":
            # show PEM markers only, not full cert bodies
            for line in raw.decode("utf-8", errors="replace").splitlines():
                if "BEGIN" in line or "END" in line:
                    print(f"  {line}")
except Exception as e:
    print(f"failed to parse secret: {e}")
' 2>&1 || true
		echo

		echo "----- clusteroperator cluster-api -----"
		oc get co cluster-api -o yaml 2>&1 || true
		echo

		echo "----- capi-operator recent logs (Keystone / OpenStack client) -----"
		oc -n openshift-cluster-api-operator logs deploy/capi-operator --tail=200 2>&1 \
			| grep -E 'OpenStack|Keystone|proxy|ProviderClient|dial tcp|authentication|InfraCluster|UserManaged|creating OpenStack' \
			|| oc -n openshift-cluster-api-operator logs deploy/capi-operator --tail=80 2>&1 \
			|| true
		echo

		echo "===== end CAPO / proxy / Keystone debug ====="
	} | tee "${out}"
}

collect_capi_proxy_debug

collect_bootstrap_logs
