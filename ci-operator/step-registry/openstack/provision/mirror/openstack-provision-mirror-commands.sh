#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "$CONFIG_TYPE" != *"singlestackv6"* ]]; then
    echo "Skipping step due to CONFIG_TYPE not matching singlestackv6."
    exit 0
fi

retry() {
    local retries=$1
    local time=$2
    shift 2

    local count=0
    until "$@"; do
      exit=$?
      count=$(($count + 1))
      if [ $count -lt $retries ]; then
        sleep $time
      else
        return $exit
      fi
    done
    return 0
}

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
WORK_DIR=${WORK_DIR:-$(mktemp -d -t shiftstack-ci-XXXXXXXXXX)}
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
CONTROL_PLANE_NETWORK="${CONTROL_PLANE_NETWORK:-$(<"${SHARED_DIR}/CONTROL_PLANE_NETWORK")}"
BASTION_FLAVOR="${BASTION_FLAVOR:-$(<"${SHARED_DIR}/BASTION_FLAVOR")}"
BASTION_USER=${BASTION_USER:-cloud-user}

if ! openstack image show $BASTION_IMAGE >/dev/null; then
		echo "ERROR: Bastion image does not exist: $BASTION_IMAGE"
		exit 1
fi

if ! openstack flavor show $BASTION_FLAVOR >/dev/null; then
		echo "ERROR: Bastion flavor does not exist: $BASTION_FLAVOR"
		exit 1
fi

openstack keypair create --public-key ${CLUSTER_PROFILE_DIR}/ssh-publickey mirror-${CLUSTER_NAME}-${CONFIG_TYPE} >/dev/null
>&2 echo "Created keypair: mirror-${CLUSTER_NAME}-${CONFIG_TYPE}"

sg_id="$(openstack security group create -f value -c id mirror-${CLUSTER_NAME}-${CONFIG_TYPE} \
  --description "Mirror security group for $CLUSTER_NAME")"
>&2 echo "Created mirror security group for ${CLUSTER_NAME}: ${sg_id}"
openstack security group rule create --ingress --protocol tcp --ethertype IPv4 --remote-ip "0.0.0.0/0" --dst-port 22 --description "${CLUSTER_NAME} SSH IPv4" "$sg_id"
openstack security group rule create --ingress --protocol tcp --ethertype IPv6 --remote-ip "::/0" --dst-port 22 --description "${CLUSTER_NAME} SSH IPv6" "$sg_id"

# Restrict registry and mitm proxy to the cluster's IPv6 subnet
if [[ -n "${MIRROR_IPV4_NETWORK:-}" ]]; then
  # Get the IPv6 subnet CIDR for vexxhost
  IPV6_SUBNET_CIDR="${MACHINES_SUBNET_v6_RANGE:-2604:e100:4::/64}"
  openstack security group rule create --ingress --protocol tcp --ethertype IPv6 --remote-ip "${IPV6_SUBNET_CIDR}" --dst-port 5000 --description "${CLUSTER_NAME} mirror registry" "$sg_id"
  openstack security group rule create --ingress --protocol tcp --ethertype IPv6 --remote-ip "${IPV6_SUBNET_CIDR}" --dst-port 13001 --description "${CLUSTER_NAME} openstack-mitm proxy IPv6" "$sg_id"
  # Allow IPv4 access to mitm proxy from anywhere (CI infrastructure needs to reach it)
  openstack security group rule create --ingress --protocol tcp --ethertype IPv4 --remote-ip "0.0.0.0/0" --dst-port 13001 --description "${CLUSTER_NAME} openstack-mitm proxy IPv4" "$sg_id"
else
  # For hwoffload (dualstack network), allow from anywhere since we don't know the subnet
  openstack security group rule create --ingress --protocol tcp --ethertype IPv6 --remote-ip "::/0" --dst-port 5000 --description "${CLUSTER_NAME} mirror registry" "$sg_id"
fi
>&2 echo "Created necessary security group rules in ${sg_id}"

# Build network parameters based on environment
# For dualstack networks (hwoffload): use single network with both IPv4+IPv6
# For separate networks (vexxhost): attach to both networks to get IPv4 and IPv6
if [[ -n "${MIRROR_IPV4_NETWORK:-}" ]]; then
  network_params="--network ${MIRROR_IPV4_NETWORK} --network $CONTROL_PLANE_NETWORK"
  echo "Using dual network setup: IPv4=${MIRROR_IPV4_NETWORK}, IPv6=${CONTROL_PLANE_NETWORK}"
else
  network_params="--network $CONTROL_PLANE_NETWORK"
  echo "Using single dualstack network: ${CONTROL_PLANE_NETWORK}"
fi

# On vexxhost, skip block-device as it may cause server creation issues
if [[ -n "${MIRROR_IPV4_NETWORK:-}" ]]; then
  server_params="$network_params --image $BASTION_IMAGE --flavor $BASTION_FLAVOR \
    --security-group $sg_id --key-name mirror-${CLUSTER_NAME}-${CONFIG_TYPE}"
else
  server_params="$network_params --image $BASTION_IMAGE --flavor $BASTION_FLAVOR \
    --security-group $sg_id --key-name mirror-${CLUSTER_NAME}-${CONFIG_TYPE} \
    --block-device source_type=blank,destination_type=volume,volume_size=70,delete_on_termination=true"
fi

echo "Creating server with command:"
echo "  openstack server create --wait -f value -c id $server_params mirror-$CLUSTER_NAME-${CONFIG_TYPE}"

server_id="$(openstack server create --wait -f value -c id $server_params \
		"mirror-$CLUSTER_NAME-${CONFIG_TYPE}" | tr -d '[:space:]')"

# Verify server_id is a valid UUID (not an error message)
if [[ ! "$server_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
	echo "ERROR: Server creation failed. Got invalid server ID: '$server_id'"
	echo "This might indicate:"
	echo "  - Quota exceeded"
	echo "  - Flavor '$BASTION_FLAVOR' not available"
	echo "  - Network/port creation failed"
	echo "  - Image '$BASTION_IMAGE' not found or inaccessible"
	exit 1
fi

>&2 echo "Created nova server mirror-${CLUSTER_NAME}-${CONFIG_TYPE}: ${server_id}"

# Wait for server to be fully available in OpenStack database
# Vexxhost has timing issues even after --wait completes
echo "Waiting 30 seconds for server to be fully initialized in OpenStack..."
sleep 30

IPV4_REGEX="((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])"
IPV6_REGEX="(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))"

# Get server IPs
mirror_ipv4="$(openstack server show -f value -c addresses mirror-$CLUSTER_NAME-${CONFIG_TYPE} | grep -oE $IPV4_REGEX)"
mirror_ipv6="$(openstack server show -f value -c addresses mirror-$CLUSTER_NAME-${CONFIG_TYPE} | grep -oE $IPV6_REGEX)"

echo "Mirror VM fixed IPv4: ${mirror_ipv4}"
echo "Mirror VM IPv6: ${mirror_ipv6}"

# Use fixed IPv4 for SSH (vexxhost public IPs are directly accessible, no floating IP needed)
mirror_ssh_ip="${mirror_ipv4}"

echo "Mirror VM SSH IP: ${mirror_ssh_ip}"

# configure the local container environment to have the correct SSH configuration
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${BASTION_USER}:x:$(id -u):0:${BASTION_USER} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

if [[ -f "${SHARED_DIR}/squid-credentials.txt" ]]; then
   proxy_host=$(yq -r ".clouds.${OS_CLOUD}.auth.auth_url" "$OS_CLIENT_CONFIG_FILE" | cut -d/ -f3 | cut -d: -f1)
   proxy_credentials=$(<"${SHARED_DIR}/squid-credentials.txt")
   echo "Using proxy $proxy_host for SSH connection to mirror"
   USE_PROXY=true
else
  echo "No squid-credentials.txt found, using direct SSH connection to mirror"
  USE_PROXY=false
fi

ssh_via_proxy() {
    local command=$1
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey -o ProxyCommand="nc --proxy-auth ${proxy_credentials} --proxy ${proxy_host}:3128 %h %p" $BASTION_USER@$mirror_ssh_ip "$command"
}

scp_via_proxy() {
    local src=$1
    local dest=$2
    scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey -o ProxyCommand="nc --proxy-auth ${proxy_credentials} --proxy ${proxy_host}:3128 %h %p" $src $dest
}

ssh_direct() {
    local command=$1
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey $BASTION_USER@$mirror_ssh_ip "$command"
}

scp_direct() {
    local src=$1
    local dest=$2
    scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey $src $dest
}

# Set up function aliases based on whether proxy is available
if [[ "$USE_PROXY" == "true" ]]; then
    ssh_mirror() { ssh_via_proxy "$@"; }
    scp_mirror() { scp_via_proxy "$@"; }
else
    ssh_mirror() { ssh_direct "$@"; }
    scp_mirror() { scp_direct "$@"; }
fi

if ! retry 60 5 ssh_mirror "uname -a"; then
		echo "ERROR: Mirror VM is not reachable via $mirror_ssh_ip - check logs:"
    openstack console log show ${server_id}
		exit 1
fi

MIRROR_REGISTRY_DNS_NAME="mirror-registry.${CLUSTER_NAME}.${BASE_DOMAIN}"
MIRROR_REGISTRY_CREDENTIALS=$(<"/var/run/vault/mirror-registry/registry_creds")
scp_mirror "/var/run/vault/mirror-registry/registry_creds_encrypted_htpasswd" $BASTION_USER@$mirror_ssh_ip:/tmp/htpasswd

echo "Deploying the mirror registry"
if [[ -n "${MIRROR_IPV4_NETWORK:-}" ]]; then
  # Vexxhost: use directory on root disk (no separate block device)
  >&2 cat << EOF > $WORK_DIR/deploy_mirror.sh
#!/usr/bin/env bash
set -e
sudo mkdir -p /opt/registry/{auth,certs,data}
EOF
else
  # hwoffload: use separate block device
  >&2 cat << EOF > $WORK_DIR/deploy_mirror.sh
#!/usr/bin/env bash
set -e
# Find the additional block device (not the root device)
# Get the root device and exclude it, then find first unused disk
ROOT_DEVICE=\$(lsblk -no PKNAME \$(findmnt -n -o SOURCE /))
DEVICE=\$(lsblk -dn -o NAME,TYPE | awk -v root="\$ROOT_DEVICE" '\$2=="disk" && \$1!=root {print "/dev/" \$1; exit}')
if [[ -z "\$DEVICE" ]]; then
    echo "ERROR: Could not find additional block device for registry data"
    echo "Root device: \$ROOT_DEVICE"
    lsblk -a
    exit 1
fi
echo "Using block device: \$DEVICE (root device: \$ROOT_DEVICE)"
sudo mkfs.xfs \$DEVICE
sudo mkdir -p /opt/registry/{auth,certs,data}
sudo mount \$DEVICE /opt/registry/data
EOF
fi

>&2 cat << EOF >> $WORK_DIR/deploy_mirror.sh
sudo openssl req -newkey rsa:4096 -nodes -sha256 -keyout /opt/registry/certs/domain.key -x509 -days 1 -subj "/CN=mirror-$CLUSTER_NAME-${CONFIG_TYPE}" -addext "subjectAltName=DNS:$MIRROR_REGISTRY_DNS_NAME,DNS:mirror-$CLUSTER_NAME-${CONFIG_TYPE}" -out /opt/registry/certs/domain.crt
sudo cp /opt/registry/certs/domain.crt /etc/pki/ca-trust/source/anchors/domain.crt   
sudo mv /tmp/htpasswd /opt/registry/auth/htpasswd
sudo update-ca-trust
sudo dnf install -y podman
sudo podman create --name registry -p 5000:5000 --net host \
    -e "REGISTRY_AUTH=htpasswd" \
    -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" \
    -e "REGISTRY_AUTH_HTPASSWD_REALM='Registry Realm'" \
    -v /opt/registry/auth:/auth:Z \
    -v /opt/registry/certs:/certs:Z \
    -v /opt/registry/data:/var/lib/registry:z \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
    quay.io/libpod/registry:2.8.2
sudo podman start registry
curl -u "$MIRROR_REGISTRY_CREDENTIALS" --connect-timeout 5 --max-time 10 --retry 5 --retry-delay 0 --retry-max-time 40 -k https://localhost:5000/v2/_catalog
EOF

scp_mirror $WORK_DIR/deploy_mirror.sh $BASTION_USER@$mirror_ssh_ip:/tmp
ssh_mirror "chmod +x /tmp/deploy_mirror.sh"
ssh_mirror "bash -c /tmp/deploy_mirror.sh"

echo "${MIRROR_REGISTRY_DNS_NAME}:5000" >"${SHARED_DIR}/mirror_registry_url"
scp_mirror $BASTION_USER@$mirror_ssh_ip:/opt/registry/certs/domain.crt ${SHARED_DIR}/additional_trust_bundle
echo $mirror_ssh_ip > "${SHARED_DIR}/MIRROR_SSH_IP"
echo $mirror_ipv6 > "${SHARED_DIR}/MIRROR_REGISTRY_IP"

# Deploy openstack-mitm proxy for IPv6-to-IPv4 API translation (vexxhost)
if [[ -n "${MIRROR_IPV4_NETWORK:-}" ]]; then
	echo "Deploying openstack-mitm proxy on mirror VM for OpenStack API access"
	REAL_AUTH_URL=$(yq -r ".clouds.${OS_CLOUD}.auth.auth_url" "$OS_CLIENT_CONFIG_FILE")
	echo "Real OpenStack API URL: ${REAL_AUTH_URL}"

	>&2 cat << EOF > $WORK_DIR/deploy_mitm.sh
#!/usr/bin/env bash
set -e

# Install squid
sudo dnf install -y squid

# Configure squid as a simple HTTPS proxy (CONNECT tunnel, no SSL bumping)
sudo bash -c 'cat > /etc/squid/squid.conf << SQUID_CONF
# Listen on port 13001
http_port 13001

# Allow CONNECT for HTTPS
acl SSL_ports port 443
acl CONNECT method CONNECT
http_access allow CONNECT SSL_ports

# Allow all HTTP
http_access allow all

# Disable caching
cache deny all

# Access logging
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# Misc
coredump_dir /var/spool/squid
SQUID_CONF'

# Create log directory
sudo mkdir -p /var/log/squid
sudo chown squid:squid /var/log/squid

# Start squid
sudo systemctl enable --now squid
sleep 3
sudo systemctl status squid
EOF

	scp_mirror $WORK_DIR/deploy_mitm.sh $BASTION_USER@$mirror_ssh_ip:/tmp/deploy_mitm.sh

	scp_mirror $WORK_DIR/deploy_mitm.sh $BASTION_USER@$mirror_ssh_ip:/tmp/deploy_mitm.sh
	ssh_mirror "chmod +x /tmp/deploy_mitm.sh"
	ssh_mirror "bash -c /tmp/deploy_mitm.sh"
	echo "openstack-mitm proxy is running on ${mirror_ipv4}:13001 and [${mirror_ipv6}]:13001"
	# Use IPv4 for the proxy so CI infrastructure can reach it
	echo $mirror_ipv4 > "${SHARED_DIR}/OPENSTACK_MITM_PROXY_IP"
fi

echo "Mirror is ready!"
