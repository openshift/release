#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" != "byon" ]]; then
    # For now, we only support the deployment of OCP into specific availability zones when pre-configuring
    # the network (BYON), for known limitations that will be addressed in the future.
    if [[ "$ZONES_COUNT" != "0" ]]; then
        echo "ZONES_COUNT was set to '${ZONES_COUNT}', although CONFIG_TYPE was not set to 'byon'."
        exit 1
    fi
    echo "Skipping step due to CONFIG_TYPE not being byon."
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
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
BASTION_FLAVOR="${BASTION_FLAVOR:-$(<"${SHARED_DIR}/BASTION_FLAVOR")}"
BASTION_USER=${BASTION_USER:-centos}
ZONES=$(<"${SHARED_DIR}"/ZONES)

mapfile -t ZONES < <(printf ${ZONES}) >/dev/null
MAX_ZONES_COUNT=${#ZONES[@]}

if [[ ! -f ${SHARED_DIR}"/BASTIONSUBNET_NET_ID" ]]; then
    echo "Failed to find ${SHARED_DIR}/BASTIONSUBNET_NET_ID, bastion network was probably not created"
    exit 1
fi
NET_ID=$(<"${SHARED_DIR}"/BASTIONSUBNET_NET_ID)

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

if [[ ${OPENSTACK_PROVIDER_NETWORK} != "" ]]; then
    echo "Provider network detected: ${OPENSTACK_PROVIDER_NETWORK}"
    if ! openstack network show ${OPENSTACK_PROVIDER_NETWORK} >/dev/null; then
        echo "ERROR: Provider network not found: ${OPENSTACK_PROVIDER_NETWORK}"
        exit 1
    fi
    PROV_NET_ID=$(openstack network show -c id -f value "${OPENSTACK_PROVIDER_NETWORK}")
    echo "Provider network ID: ${PROV_NET_ID}"
    PROV_NET_ARGS="--network ${PROV_NET_ID} "
else
  PROV_NET_ARGS=""
fi

openstack keypair create --public-key ${CLUSTER_PROFILE_DIR}/ssh-publickey ${CLUSTER_NAME} >/dev/null
>&2 echo "Created keypair: ${CLUSTER_NAME}"

sg_id="$(openstack security group create -f value -c id $CLUSTER_NAME)"
>&2 echo "Created security group for ${CLUSTER_NAME}: ${sg_id}"
openstack security group rule create --ingress --protocol tcp --dst-port 22 --description "${CLUSTER_NAME} SSH" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol tcp --dst-port 3128 --remote-ip 0.0.0.0/0 --description "${CLUSTER_NAME} squid" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol tcp --dst-port 3130 --remote-ip 0.0.0.0/0 --description "${CLUSTER_NAME} squid" "$sg_id" >/dev/null
>&2 echo "Security group rules created in ${sg_id} to allow SSH and squid access"

openstack server create --wait $ZONES_ARGS \
		--image "$BASTION_IMAGE" \
		--flavor "$BASTION_FLAVOR" \
		--network "$NET_ID" $PROV_NET_ARGS \
		--security-group "$sg_id" \
		--key-name "$CLUSTER_NAME" \
		"bastionproxy-$CLUSTER_NAME" >/dev/null
server_id="$(openstack server show bastionproxy-${CLUSTER_NAME} -f value -c id)"
>&2 echo "Created nova server bastionproxy-${CLUSTER_NAME}: ${server_id}"

bastion_fip="$(openstack floating ip create -f value -c floating_ip_address \
		--description "bastionproxy $CLUSTER_NAME FIP" \
		--tag bastionproxy-$CLUSTER_NAME \
		"$OPENSTACK_EXTERNAL_NETWORK")"
>&2 echo "Created floating IP ${bastion_fip}"
>&2 openstack server add floating ip "$server_id" "$bastion_fip"
echo ${bastion_fip} >> ${SHARED_DIR}/DELETE_FIPS
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
SQUID_IP=$bastion_fip

echo "Deploying squid on $SQUID_IP"

PASSWORD="$(uuidgen | sha256sum | cut -b -32)"
SQUID_AUTH="${CLUSTER_NAME}:${PASSWORD}"

>&2 cat << EOF > $WORK_DIR/deploy_squid.sh
sudo dnf install -y squid
sudo bash -c "cat << EOF > /etc/squid/squid.conf
acl localnet src 0.0.0.0/0
acl SSL_ports port 443
acl SSL_ports port 1025-65535
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 1025-65535
acl CONNECT method CONNECT
http_access deny !Safe_ports
http_access deny !SSL_ports
http_access allow localnet
http_access deny all
http_port 3128
https_port 3130 cert=/etc/squid/certs/domain.crt key=/etc/squid/certs/domain.key cafile=/etc/squid/certs/domain.crt
# Leave coredumps in the first cache dir
coredump_dir /var/spool/squid
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /etc/squid/htpasswd
auth_param basic children 5
auth_param basic realm Squid Basic Authentication
auth_param basic credentialsttl 2 hours
acl auth_users proxy_auth REQUIRED
http_access allow auth_users
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
EOF
$SCP_CMD $WORK_DIR/deploy_squid.sh $BASTION_USER@$bastion_fip:/tmp
$SSH_CMD chmod +x /tmp/deploy_squid.sh
$SSH_CMD bash -c /tmp/deploy_squid.sh

cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://$SQUID_AUTH@${bastion_fip}:3128/
export HTTPS_PROXY=http://$SQUID_AUTH@${bastion_fip}:3128/
export NO_PROXY="redhat.io,quay.io,redhat.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"

export http_proxy=http://$SQUID_AUTH@${bastion_fip}:3128/
export https_proxy=http://$SQUID_AUTH@${bastion_fip}:3128/
export no_proxy="redhat.io,quay.io,redhat.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"
EOF

echo "Bastion proxy is ready!"
