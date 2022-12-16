#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "$CONFIG_TYPE" != "proxy" ]]; then
    if [[ "$ZONES_COUNT" != "0" ]]; then
      echo "ZONES_COUNT was set to '${ZONES_COUNT}', although CONFIG_TYPE was not set to 'proxy'."
      exit 1
    fi
    echo "Skipping step due to CONFIG_TYPE not being proxy."
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
MACHINES_NET_ID=$(<"${SHARED_DIR}"/MACHINES_NET_ID)
MACHINES_SUBNET_ID=$(<"${SHARED_DIR}"/MACHINES_SUBNET_ID)
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
BASTION_FLAVOR="${BASTION_FLAVOR:-$(<"${SHARED_DIR}/BASTION_FLAVOR")}"
BASTION_USER=${BASTION_USER:-cloud-user}
ZONES=$(<"${SHARED_DIR}"/ZONES)

mapfile -t ZONES < <(printf ${ZONES}) >/dev/null
MAX_ZONES_COUNT=${#ZONES[@]}

if [[ ${ZONES_COUNT} -gt ${MAX_ZONES_COUNT} ]]; then
  echo "Too many zones were requested: ${ZONES_COUNT}; only ${MAX_ZONES_COUNT} are available: ${ZONES[*]}"
  exit 1
fi

if [[ "${ZONES_COUNT}" == "0" ]]; then
  ZONES_ARGS=""
elif [[ "${ZONES_COUNT}" == "1" ]]; then
  for ((i=0; i<${MAX_ZONES_COUNT}; ++i )) ; do
    ZONES_ARGS+="--availability-zone ${ZONES[$i]} "
  done
else
  # For now, we only support a cluster within a single AZ.
  # This will change in the future.
  echo "Wrong ZONE_COUNT, can only be 0 or 1, got ${ZONES_COUNT}"
  exit 1
fi

if ! openstack image show $BASTION_IMAGE >/dev/null; then
		echo "ERROR: Bastion image does not exist: $BASTION_IMAGE"
		exit 1
fi

if ! openstack flavor show $BASTION_FLAVOR >/dev/null; then
		echo "ERROR: Bastion flavor does not exist: $BASTION_FLAVOR"
		exit 1
fi

openstack keypair create --public-key ${CLUSTER_PROFILE_DIR}/ssh-publickey bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE} >/dev/null
>&2 echo "Created keypair: bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}"

sg_id="$(openstack security group create -f value -c id bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE} \
  --description "Bastion security group for $CLUSTER_NAME")"
>&2 echo "Created bastion security group for ${CLUSTER_NAME}: ${sg_id}"
openstack security group rule create --ingress --protocol tcp --dst-port 22 --description "${CLUSTER_NAME} SSH" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol udp --dst-port 53 --description "${CLUSTER_NAME} DNS" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol tcp --dst-port 3128 --remote-ip 0.0.0.0/0 --description "${CLUSTER_NAME} squid" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol tcp --dst-port 3130 --remote-ip 0.0.0.0/0 --description "${CLUSTER_NAME} squid" "$sg_id" >/dev/null
>&2 echo "Created necessary security group rules in ${sg_id}"

server_params=" --image $BASTION_IMAGE --flavor $BASTION_FLAVOR $ZONES_ARGS \
  --security-group $sg_id --key-name bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}"

if [[ -f ${SHARED_DIR}"/BASTION_NET_ID" ]]; then
  BASTION_NET_ID=$(<"${SHARED_DIR}"/BASTION_NET_ID)
  server_params+=" --network $BASTION_NET_ID"
fi

server_params+=" --network $MACHINES_NET_ID"

server_id="$(openstack server create -f value -c id $server_params \
		"bastionproxy-$CLUSTER_NAME-${CONFIG_TYPE}")"
>&2 echo "Created nova server bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}: ${server_id}"

bastion_fip="$(openstack floating ip create -f value -c floating_ip_address \
		--description "bastionproxy $CLUSTER_NAME FIP" \
		--tag bastionproxy-$CLUSTER_NAME \
		"$OPENSTACK_EXTERNAL_NETWORK")"
>&2 echo "Created floating IP ${bastion_fip}"
>&2 openstack server add floating ip "$server_id" "$bastion_fip"
echo ${bastion_fip} >> ${SHARED_DIR}/DELETE_FIPS
echo ${bastion_fip} > ${SHARED_DIR}/BASTION_FIP
echo ${BASTION_USER} > ${SHARED_DIR}/BASTION_USER
cp ${SHARED_DIR}/DELETE_FIPS ${ARTIFACT_DIR}

# configure the local container environment to have the correct SSH configuration
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${BASTION_USER}:x:$(id -u):0:${BASTION_USER} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

# shellcheck disable=SC2140
SSH_ARGS="-o ConnectTimeout=10 -o "StrictHostKeyChecking=no" -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey"
SSH_CMD="ssh $SSH_ARGS $BASTION_USER@$bastion_fip"
SCP_CMD="scp $SSH_ARGS"

#if ! retry 60 5 $SSH_CMD uname -a >/dev/null; then
if ! retry 60 5 $SSH_CMD uname -a; then
		echo "ERROR: Bastion proxy is not reachable via $bastion_fip - check logs:"
    openstack console log show ${server_id}
		exit 1
fi

PASSWORD="$(uuidgen | sha256sum | cut -b -32)"
SQUID_AUTH="${CLUSTER_NAME}:${PASSWORD}"
echo ${SQUID_AUTH}>${SHARED_DIR}/SQUID_AUTH

MACHINES_GATEWAY_IP=""
SQUID_IP=$bastion_fip
if [[ "${CONFIG_TYPE}" == "proxy" ]]; then
  # Right now we assume that the bastion will be connected to one machines network via a port.
  # This command will have to be revisited if we want more ports on this machine.
  PROXY_INTERFACE="$(openstack port list --network $MACHINES_NET_ID --server "$server_id" \
    -c fixed_ips -f value |cut -d':' -f3 |cut -f1 -d '}' |sed -e "s/'//" -e "s/'$//")"
  SQUID_IP=$PROXY_INTERFACE
  echo ${PROXY_INTERFACE}>${SHARED_DIR}/PROXY_INTERFACE
  openstack subnet set --no-dns-nameservers --dns-nameserver ${PROXY_INTERFACE} ${MACHINES_SUBNET_ID}
  echo "Subnet ${MACHINES_SUBNET_ID} was updated to use ${SQUID_IP} as DNS server"
  if [[ "${NETWORK_TYPE}" == "Kuryr" ]]; then
    MACHINES_GATEWAY_IP="$(openstack subnet show -c gateway_ip -f value $MACHINES_SUBNET_ID)"
    echo "Subnet ${MACHINES_SUBNET_ID} has ${MACHINES_GATEWAY_IP} as gateway"
  fi
fi

echo "Deploying squid on $SQUID_IP"

>&2 cat << EOF > $WORK_DIR/deploy_squid.sh
sudo dnf install -y squid dnsmasq

sudo bash -c "cat << EOF >> /etc/dnsmasq.conf
listen-address=${SQUID_IP}
EOF"

sudo bash -c "cat << EOF > /etc/squid/squid.conf
acl localnet src all
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 1025-65535
http_port 3128
https_port 3130 cert=/etc/squid/certs/domain.crt key=/etc/squid/certs/domain.key cafile=/etc/squid/certs/domain.crt
# Leave coredumps in the first cache dir
coredump_dir /var/spool/squid
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /etc/squid/htpasswd
auth_param basic children 5
auth_param basic realm Squid Basic Authentication
auth_param basic credentialsttl 2 hours
acl auth_users proxy_auth REQUIRED
http_access deny !auth_users
http_access deny !Safe_ports
http_access allow localnet
http_access deny all
EOF"

sudo mkdir -p /etc/squid/certs
cd /etc/squid/certs
sudo openssl req -newkey rsa:4096 -nodes -sha256 -keyout domain.key -x509 -days 1 \
 -addext "subjectAltName = IP:$SQUID_IP" -subj "/C=US/ST=Denial/L=Springfield/O=RedHat/CN=shiftstack.com" -out domain.crt
sudo cp /etc/squid/certs/domain.crt /etc/pki/ca-trust/source/anchors/domain.crt
sudo update-ca-trust
sudo yum install -y httpd-tools
sudo htpasswd -bBc /etc/squid/htpasswd $CLUSTER_NAME $PASSWORD

sudo systemctl start squid
sudo systemctl start dnsmasq
EOF

if [[ $MACHINES_GATEWAY_IP != "" ]]; then
  cat >> $WORK_DIR/deploy_squid.sh <<EOL
#To reach the Pods Network it needs to go through the internal Router.
#The 10.128.0.0/14 is the default Pods subnet pool CIDR.
sudo ip route add 10.128.0.0/14 via $MACHINES_GATEWAY_IP
EOL
fi

$SCP_CMD $WORK_DIR/deploy_squid.sh $BASTION_USER@$bastion_fip:/tmp
$SSH_CMD chmod +x /tmp/deploy_squid.sh
$SSH_CMD bash -c /tmp/deploy_squid.sh
$SCP_CMD $BASTION_USER@$bastion_fip:/etc/squid/certs/domain.crt ${SHARED_DIR}/

if [[ -f "${SHARED_DIR}/osp-ca.crt" ]]; then
  printf "\n" >> "${SHARED_DIR}/osp-ca.crt"
  cat "${SHARED_DIR}"/domain.crt >> "${SHARED_DIR}/osp-ca.crt"
fi

echo "Bastion proxy is ready!"
