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

	# Resolve names outside the piped brace group (local is invalid in a subshell).
	local pod
	pod="$(oc -n openshift-cluster-api-operator get pods -l k8s-app=capi-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

	local http_proxy https_proxy no_proxy auth_url keystone_url release_image cli_image
	http_proxy="$(oc get proxy cluster -o jsonpath='{.status.httpProxy}' 2>/dev/null || true)"
	https_proxy="$(oc get proxy cluster -o jsonpath='{.status.httpsProxy}' 2>/dev/null || true)"
	no_proxy="$(oc get proxy cluster -o jsonpath='{.status.noProxy}' 2>/dev/null || true)"
	auth_url="$(
		oc -n openshift-cluster-api get secret openstack-cloud-credentials -o json 2>/dev/null \
			| python3 -c '
import sys, json, base64, re
try:
    data = json.load(sys.stdin).get("data") or {}
    text = base64.b64decode(data.get("clouds.yaml", "")).decode("utf-8", errors="replace")
    m = re.search(r"auth_url:\s*(\S+)", text)
    print(m.group(1) if m else "")
except Exception:
    print("")
' 2>/dev/null || true
	)"
	# Keystone root for curl (strip /v3 suffix if present).
	keystone_url="${auth_url%/}"
	keystone_url="${keystone_url%/v3}"
	[[ -n "${keystone_url}" && "${keystone_url}" != */ ]] && keystone_url="${keystone_url}/"

	release_image="$(oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>/dev/null || true)"
	cli_image=""
	if [[ -n "${release_image}" ]]; then
		# tools image includes curl; prefer it over cli for connectivity probes.
		cli_image="$(oc adm release info "${release_image}" --image-for=tools 2>/dev/null \
			|| oc adm release info "${release_image}" --image-for=cli 2>/dev/null \
			|| true)"
	fi

	local connectivity_log
	connectivity_log="$(mktemp)"
	run_keystone_connectivity_matrix "${connectivity_log}" "${cli_image}" "${keystone_url}" \
		"${http_proxy}" "${https_proxy}" "${no_proxy}" || true

	{
		echo "===== CAPO / proxy / Keystone debug ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ====="
		echo "CONFIG_TYPE=${CONFIG_TYPE:-}"
		echo "keystone_url=${keystone_url:-<empty>}"
		echo "cli_image=${cli_image:-<empty>}"
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

		echo "----- Keystone connectivity matrix (in-cluster debug pod) -----"
		cat "${connectivity_log}" 2>&1 || true
		echo

		echo "----- machine-api comparison (proxy env + Keystone-related logs) -----"
		dump_operator_proxy_comparison "openshift-machine-api" "machine-api-controllers" \
			"machine-api-controllers" 2>&1 || true
		echo

		echo "----- openstack-cloud-controller-manager comparison -----"
		if oc -n openshift-cloud-controller-manager get deploy openstack-cloud-controller-manager >/dev/null 2>&1; then
			dump_operator_proxy_comparison "openshift-cloud-controller-manager" \
				"openstack-cloud-controller-manager" "openstack-cloud-controller-manager" 2>&1 || true
		else
			echo "openstack-cloud-controller-manager deployment not found"
			oc -n openshift-cloud-controller-manager get deploy,pods 2>&1 || true
		fi
		echo

		echo "----- clusteroperator machine-api (Available / messages) -----"
		oc get co machine-api -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} msg={.message}{"\n"}{end}' 2>&1 || true
		echo

		echo "===== end CAPO / proxy / Keystone debug ====="
	} | tee "${out}"

	rm -f "${connectivity_log}"
}

# Dump proxy-related env and filtered logs for another in-cluster OpenStack client.
dump_operator_proxy_comparison() {
	local namespace="$1"
	local deploy="$2"
	local container="${3:-}"

	echo "namespace=${namespace} deploy=${deploy}"
	if ! oc -n "${namespace}" get deploy "${deploy}" >/dev/null 2>&1; then
		echo "deployment not found"
		oc -n "${namespace}" get deploy,pods 2>&1 || true
		return 0
	fi

	echo "Deployment proxy-related env:"
	oc -n "${namespace}" get deploy "${deploy}" -o json 2>&1 | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    for c in d.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
        print("container=%s" % c.get("name"))
        for e in c.get("env") or []:
            name = e.get("name", "")
            if "PROXY" in name.upper():
                print("  %s=%s" % (name, e.get("value", "<valueFrom>")))
except Exception as err:
    print("parse failed: %s" % err)
' 2>&1 || true

	local cmp_pod
	cmp_pod="$(oc -n "${namespace}" get pods -l "k8s-app=${deploy}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
	if [[ -z "${cmp_pod}" ]]; then
		cmp_pod="$(oc -n "${namespace}" get pods -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
	fi
	if [[ -n "${cmp_pod}" ]]; then
		echo "pod=${cmp_pod} live PROXY env:"
		local exec_args=(-n "${namespace}" exec "${cmp_pod}")
		if [[ -n "${container}" ]]; then
			# container may not match; ignore failure and retry without -c
			oc "${exec_args[@]}" -c "${container}" -- \
				/bin/sh -c 'env | grep -E "^(HTTP|HTTPS|NO|http|https|no)_?PROXY=" | sort' 2>/dev/null \
				|| oc "${exec_args[@]}" -- \
					/bin/sh -c 'env | grep -E "^(HTTP|HTTPS|NO|http|https|no)_?PROXY=" | sort' 2>&1 \
				|| true
		else
			oc "${exec_args[@]}" -- \
				/bin/sh -c 'env | grep -E "^(HTTP|HTTPS|NO|http|https|no)_?PROXY=" | sort' 2>&1 || true
		fi
	fi

	echo "Recent logs (filtered):"
	oc -n "${namespace}" logs "deploy/${deploy}" --all-containers --tail=120 2>&1 \
		| grep -E 'OpenStack|Keystone|proxy|ProviderClient|dial tcp|authentication|gophercloud|auth_url|13000|connection timed out' \
		|| echo "(no matching log lines; last 40 lines follows)"
	oc -n "${namespace}" logs "deploy/${deploy}" --all-containers --tail=40 2>&1 \
		| grep -E 'OpenStack|Keystone|proxy|dial tcp|authentication|13000|timed out' || true
}

# Short-lived in-cluster pod: curl Keystone via http proxy, https proxy, and direct.
run_keystone_connectivity_matrix() {
	local out_file="$1"
	local cli_image="$2"
	local keystone_url="$3"
	local http_proxy="$4"
	local https_proxy="$5"
	local no_proxy="$6"

	local ns="openshift-cluster-api-operator"
	local pod="capi-keystone-curl-debug"

	{
		echo "keystone_url=${keystone_url:-<empty>}"
		echo "http_proxy_set=$([[ -n ${http_proxy} ]] && echo yes || echo no)"
		echo "https_proxy_set=$([[ -n ${https_proxy} ]] && echo yes || echo no)"
		echo "cli_image=${cli_image:-<empty>}"

		if [[ -z "${keystone_url}" ]]; then
			echo "SKIP: could not determine Keystone URL from openstack-cloud-credentials"
			return 0
		fi
		if [[ -z "${cli_image}" ]]; then
			echo "SKIP: could not resolve cli image from clusterversion"
			return 0
		fi

		oc -n "${ns}" delete pod "${pod}" --wait=true --ignore-not-found=true 2>&1 || true

		# Copy user-ca-bundle into the operator namespace for the optional mount.
		if oc -n openshift-config get configmap user-ca-bundle >/dev/null 2>&1; then
			oc -n openshift-config get configmap user-ca-bundle -o json 2>/dev/null \
				| python3 -c '
import sys, json
cm = json.load(sys.stdin)
out = {
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {"name": "user-ca-bundle", "namespace": "'"${ns}"'"},
  "data": cm.get("data") or {},
}
print(json.dumps(out))
' | oc apply -f - 2>&1 || true
		fi

		# Manifest keeps proxy credentials with special chars intact (no shell eval).
		local manifest
		manifest="$(mktemp)"
		python3 - "${manifest}" "${ns}" "${pod}" "${cli_image}" "${http_proxy}" "${https_proxy}" "${no_proxy}" <<'PY'
import json, sys
manifest, ns, pod, image, http_proxy, https_proxy, no_proxy = sys.argv[1:8]
doc = {
    "apiVersion": "v1",
    "kind": "Pod",
    # k8s-app=capi-operator matches allow-egress-operators NetworkPolicy in this ns.
    "metadata": {
        "name": pod,
        "namespace": ns,
        "labels": {"app": "capi-keystone-curl-debug", "k8s-app": "capi-operator"},
    },
    "spec": {
        "restartPolicy": "Never",
        "containers": [{
            "name": "curl",
            "image": image,
            "command": ["sleep", "600"],
            "env": [
                {"name": "HTTP_PROXY", "value": http_proxy},
                {"name": "HTTPS_PROXY", "value": https_proxy},
                {"name": "NO_PROXY", "value": no_proxy},
                {"name": "http_proxy", "value": http_proxy},
                {"name": "https_proxy", "value": https_proxy},
                {"name": "no_proxy", "value": no_proxy},
                {"name": "KEYSTONE_URL", "value": ""},  # patched below
            ],
            "volumeMounts": [{
                "name": "user-ca",
                "mountPath": "/etc/pki/ca-trust/source/anchors/user-ca-bundle.crt",
                "subPath": "ca-bundle.crt",
                "readOnly": True,
            }],
        }],
        "volumes": [{
            "name": "user-ca",
            "configMap": {"name": "user-ca-bundle", "optional": True},
        }],
    },
}
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(doc, f)
PY
		# Inject Keystone URL via a second python pass (argv-safe).
		python3 - "${manifest}" "${keystone_url}" <<'PY'
import json, sys
path, keystone_url = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
for env in doc["spec"]["containers"][0]["env"]:
    if env["name"] == "KEYSTONE_URL":
        env["value"] = keystone_url
        break
else:
    doc["spec"]["containers"][0]["env"].append({"name": "KEYSTONE_URL", "value": keystone_url})
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f)
PY

		echo "Creating debug pod ${ns}/${pod}"
		oc apply -f "${manifest}" 2>&1 || true
		rm -f "${manifest}"

		if ! oc -n "${ns}" wait --for=condition=Ready "pod/${pod}" --timeout=120s 2>&1; then
			echo "DEBUG pod not Ready; describe:"
			oc -n "${ns}" describe "pod/${pod}" 2>&1 || true
			oc -n "${ns}" delete pod "${pod}" --wait=false --ignore-not-found=true 2>&1 || true
			return 0
		fi

		# Refresh CA trust inside the pod when the anchor was mounted.
		oc -n "${ns}" exec "${pod}" -- /bin/sh -c 'command -v update-ca-trust >/dev/null && update-ca-trust || true' 2>&1 || true

		# Use proxy env already on the pod (avoids re-quoting credentials on the host).
		echo
		echo "=== TEST A: Keystone via HTTP_PROXY (:3128), TLS verify off (-k) ==="
		oc -n "${ns}" exec "${pod}" -- /bin/sh -c \
			'curl -vk --connect-timeout 10 --max-time 20 --proxy "$HTTP_PROXY" --noproxy "" "$KEYSTONE_URL" -o /dev/null -w "http_code=%{http_code} remote_ip=%{remote_ip}\n"' \
			2>&1 || echo "TEST A failed (exit $?)"

		echo
		echo "=== TEST B: Keystone via HTTPS_PROXY (:3130 https scheme), TLS verify off (-k) ==="
		oc -n "${ns}" exec "${pod}" -- /bin/sh -c \
			'curl -vk --connect-timeout 10 --max-time 20 --proxy "$HTTPS_PROXY" --noproxy "" "$KEYSTONE_URL" -o /dev/null -w "http_code=%{http_code} remote_ip=%{remote_ip}\n"' \
			2>&1 || echo "TEST B failed (exit $?)"

		echo
		echo "=== TEST C: Keystone via HTTPS_PROXY with default CA verify (no -k) ==="
		oc -n "${ns}" exec "${pod}" -- /bin/sh -c \
			'curl -v --connect-timeout 10 --max-time 20 --proxy "$HTTPS_PROXY" --noproxy "" "$KEYSTONE_URL" -o /dev/null -w "http_code=%{http_code} remote_ip=%{remote_ip}\n"' \
			2>&1 || echo "TEST C failed (exit $?)"

		echo
		echo "=== TEST D: Keystone DIRECT (proxy disabled) — expect timeout on BYON ==="
		oc -n "${ns}" exec "${pod}" -- /bin/sh -c \
			'curl -vk --connect-timeout 10 --max-time 15 --noproxy "*" "$KEYSTONE_URL" -o /dev/null -w "http_code=%{http_code} remote_ip=%{remote_ip}\n"' \
			2>&1 || echo "TEST D failed as expected or otherwise (exit $?)"

		echo
		echo "Deleting debug pod ${ns}/${pod}"
		oc -n "${ns}" delete pod "${pod}" --wait=false --ignore-not-found=true 2>&1 || true
	} >"${out_file}" 2>&1
}

collect_capi_proxy_debug

collect_bootstrap_logs
