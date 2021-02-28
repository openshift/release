#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Input: the clouds.yaml auth_url
# Output: the ca_cert to be added to generateconfig

export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
export CLUSTER_NAME

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION=us-east-1
export AWS_DEFAULT_OUTPUT=json
export AWS_PROFILE=openshift-ci-infra

route53_zone_id="$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_DOMAIN" \
	| jq -r '.HostedZones[] | select(.Name=="'"$BASE_DOMAIN"'.") | .Id' \
	| { read id; printf "%s" "${id#/hostedzone/}"; })"

auth_url="$(python <<-EOF
	import yaml
	f = yaml.safe_load(open("${CLUSTER_PROFILE_DIR}/clouds.yaml"))
	print(f["clouds"]["$OS_CLOUD"]["auth"]["auth_url"])
	EOF
	)"

readonly auth_url route53_zone_id
declare -r \
	proxy_domain="osproxy.${CLUSTER_NAME}.${BASE_DOMAIN}" \
	proxy_port='5443'                                     \
	server_flavor="$OPENSTACK_COMPUTE_FLAVOR"             \
	external_network="$OPENSTACK_EXTERNAL_NETWORK"        \
	artifact_dir="${SHARED_DIR}/osproxy"

declare -r \
	osproxy_url="https://github.com/shiftstack/os-proxy/releases/download/v1.0.1/os-proxy" \
	osproxy_sha512_checksum="d4a9210091e4d1ed4c697762ac5ed59625c97dbdf3ce58cc4bbd7f3821190f482e2464558fbd08ea737744a7cc496e9b6db4381c3941b8fb1c864d1bec35113f"

declare -r \
	resource_name='osproxy'                           \
	server_image='rhcos-4.6'                          \
	proxy_url="https://${proxy_domain}:${proxy_port}" \
	ignition="${artifact_dir}/proxy.ign"              \
	sg_id="${artifact_dir}/os_sg_id.txt"              \
	network_id="${artifact_dir}/os_network_id.txt"    \
	subnet_id="${artifact_dir}/os_subnet_id.txt"      \
	router_id="${artifact_dir}/os_router_id.txt"      \
	port_id="${artifact_dir}/os_port_id.txt"          \
	server_id="${artifact_dir}/os_server_id.txt"      \
	fip_id="${artifact_dir}/os_fip_id.txt"            \
	fip_ip="${artifact_dir}/os_fip_ip.txt"

get_https_certificate() {
  declare -r \
    cert_start_marker='-----BEGIN CERTIFICATE-----' \
    cert_end_marker='-----END CERTIFICATE-----' \
    target="$1"

  echo -n \
    | openssl s_client -showcerts -connect "${target}" 2>/dev/null \
    | tac \
    | sed -n "/${cert_end_marker}/,/${cert_start_marker}/p;/${cert_start_marker}/q" \
    | tac
}

write_deprovision() {
	declare -r deprovision="${SHARED_DIR}/deprovision.d/osproxy"

	mkdir -p "${SHARED_DIR}/deprovision.d"
	if [ -f "$fip_id" ]; then
		echo "openstack floating ip delete '$(<$fip_id)' || >&2 echo 'Failed deleting FIP $(<$fip_id)'" >> "$deprovision"
	fi
	if [ -f "$server_id" ]; then
		echo "openstack server delete '$(<$server_id)' || >&2 echo 'Failed deleting server $(<$server_id)'" >> "$deprovision"
	fi
	if [ -f "$port_id" ]; then
		echo "openstack port delete '$(<$port_id)' || >&2 echo 'Failed deleting port $(<$port_id)'" >> "$deprovision"
	fi
	if [ -f "$router_id" ]; then
		echo "openstack router remove subnet '$(<$router_id)' '$(<$subnet_id)' || >&2 echo 'Failed removing subnet from router'" >> "$deprovision"
		echo "openstack router delete '$(<$router_id)' || >&2 echo 'Failed deleting router $(<$router_id)'" >> "$deprovision"
	fi
	if [ -f "$subnet_id" ]; then
		echo "openstack subnet delete '$(<$subnet_id)' || >&2 echo 'Failed deleting subnet $(<$subnet_id)'" >> "$deprovision"
	fi
	if [ -f "$network_id" ]; then
		echo "openstack network delete '$(<$network_id)' || >&2 echo 'Failed deleting network $(<$network_id)'" >> "$deprovision"
	fi
	if [ -f "$sg_id" ]; then
		echo "openstack security group delete '$(<$sg_id)' || >&2 echo 'Failed deleting security group $(<$sg_id)'" >> "$deprovision"
	fi

	echo "Writing the deprovisioning file to '$deprovision':"
  cat "$deprovision" # DEBUG
  echo 'EOF'         # DEBUG
}

trap write_deprovision EXIT

mkdir -p "$artifact_dir"

cat > "$ignition" <<EOF
{
	"ignition": { "version": "3.1.0" },
	"passwd": {
		"users": [ { "name": "osproxy" } ]
	},
	"storage": {
		"files": [{
			"path": "/usr/local/bin/os-proxy",
			"mode": 493,
			"contents": {
				"source": "$osproxy_url",
				"verification": {
					"hash": "sha512-$osproxy_sha512_checksum"
				}
			}
		}]
	},
	"systemd": {
		"units": [{
			"name": "os-proxy.service",
			"enabled": true,
			"contents": "[Service]\nType=simple\nUser=osproxy\nWorkingDirectory=/var/home/osproxy\nExecStart=/usr/local/bin/os-proxy -authurl='${auth_url}' -proxyurl='${proxy_url}'\n\n[Install]\nWantedBy=multi-user.target\n"
		}]
	}
}
EOF

openstack security group create -f value -c id "$resource_name" > "$sg_id"
openstack security group rule create --ingress --protocol tcp  --dst-port "$proxy_port" --description "${resource_name} tcp in ${proxy_port}" "$(<"$sg_id")" >/dev/null
openstack security group rule create --ingress --protocol icmp --dst-port "$proxy_port" --description "${resource_name} ping" "$(<"$sg_id")" >/dev/null
openstack network create -f value -c id "$resource_name" > "$network_id"
openstack subnet create -f value -c id \
	--network "$(<"$network_id")" \
	--subnet-range '172.28.84.0/24' \
	"$resource_name" > "$subnet_id"
openstack router create -f value -c id "$resource_name" > "$router_id"
openstack router add subnet "$(<"$router_id")" "$(<"$subnet_id")"
openstack router set --external-gateway "$external_network" "$(<"$router_id")"
openstack port create -f value -c id \
	--network "$(<"$network_id")" \
	--security-group "$(<"$sg_id")" \
	"$resource_name" > "$port_id"
openstack server create -f value -c id \
	--image "$server_image" \
	--flavor "$server_flavor" \
	--nic "port-id=$(<"$port_id")" \
	--security-group "$(<"$sg_id")" \
	--user-data "$ignition" \
	"$resource_name" > "$server_id"
openstack floating ip create -f value -c id \
	--description "${resource_name} FIP" \
	"$external_network" > "$fip_id"
openstack floating ip show -f value -c floating_ip_address "$(<"$fip_id")" > "$fip_ip"
openstack server add floating ip "$(<"$server_id")" "$(<"$fip_id")"

echo "Creating DNS record for ${proxy_domain}. -> $(<"$fip_ip")"
cat > "${SHARED_DIR}/osproxy-record.json" <<EOF
{
	"Comment": "Create the os-proxy record",
	"Changes": [{
		"Action": "UPSERT",
		"ResourceRecordSet": {
			"Name": "${proxy_domain}.",
			"Type": "A",
			"TTL": 300,
			"ResourceRecords": [{"Value": "$(<"$fip_ip")"}]
		}
	}]
}
EOF

aws route53 change-resource-record-sets --hosted-zone-id "$route53_zone_id" --change-batch "file://${SHARED_DIR}/osproxy-record.json"

echo 'Waiting for os-proxy to become available...'
timeout 5m bash -c "until curl --insecure --connect-timeout 5 -X POST '${proxy_url}/v3/auth/tokens' >/dev/null 2>&1; do sleep 5; done"

echo "Proxy responding on '${proxy_url}'."

get_https_certificate "${proxy_url}" > "${SHARED_DIR}/osproxy-cert"

cat "${SHARED_DIR}/osproxy-cert"
