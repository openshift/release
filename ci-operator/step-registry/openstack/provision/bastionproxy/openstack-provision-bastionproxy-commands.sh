#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" != "byon" ]]; then
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
NET_ID=$(<"${SHARED_DIR}"/MACHINESSUBNET_NET_ID)
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

if ! openstack image show $BASTION_IMAGE >/dev/null; then
		echo "ERROR: Bastion image does not exist: $BASTION_IMAGE"
		exit 1
fi

if ! openstack flavor show $BASTION_FLAVOR >/dev/null; then
		echo "ERROR: Bastion flavor does not exist: $BASTION_FLAVOR"
		exit 1
fi

openstack keypair create --public-key ${CLUSTER_PROFILE_DIR}/ssh-publickey ${CLUSTER_NAME} >/dev/null
>&2 echo "Created keypair: ${CLUSTER_NAME}"

sg_id="$(openstack security group create -f value -c id $CLUSTER_NAME)"
>&2 echo "Created security group for ${CLUSTER_NAME}: ${sg_id}"
openstack security group rule create --ingress --protocol tcp --dst-port 22 --description "${CLUSTER_NAME} SSH" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol tcp --dst-port 8213 --description "${CLUSTER_NAME} squid" "$sg_id" >/dev/null
>&2 echo "Security group rules created in ${sg_id} to allow SSH and squid access"

server_id="$(openstack server create -f value -c id \
		--image "$BASTION_IMAGE" \
		--flavor "$BASTION_FLAVOR" \
		--network "$NET_ID" \
		--security-group "$sg_id" \
		--key-name "$CLUSTER_NAME" \
		"bastionproxy-$CLUSTER_NAME")"
>&2 echo "Created nova server ${CLUSTER_NAME}: ${server_id}"

bastion_fip="$(openstack floating ip create -f value -c floating_ip_address \
		--description "bastionproxy $CLUSTER_NAME FIP" \
		--tag bastionproxy-$CLUSTER_NAME \
		"$OPENSTACK_EXTERNAL_NETWORK")"
>&2 echo "Created floating IP ${bastion_fip}"
>&2 openstack server add floating ip "$server_id" "$bastion_fip"
echo ${bastion_fip} |awk '{print $2}' >> ${SHARED_DIR}/DELETE_FIPS
cp ${SHARED_DIR}/DELETE_FIPS ${ARTIFACT_DIR}

# configure the local container environment to have the correct SSH configuration
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${BASTION_USER:-centos}:x:$(id -u):0:${BASTION_USER:-centos} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

# shellcheck disable=SC2140
SSH_ARGS="-o ConnectTimeout=10 -o "StrictHostKeyChecking=no" -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey"
SSH_CMD="ssh $SSH_ARGS $BASTION_USER@$bastion_fip"
SCP_CMD="scp $SSH_ARGS"

#if ! retry 60 5 $SSH_CMD uname -a >/dev/null; then
if ! retry 60 5 $SSH_CMD uname -a; then
		echo "ERROR: Bastion proxy is not reachable via its floating-IP: $bastion_fip"
		exit 1
fi

echo "Deploying squid on $bastion_fip"
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
http_access deny CONNECT !SSL_ports
http_access allow localnet
http_access deny all
http_port 8213
EOF"
sudo systemctl start squid
EOF
$SCP_CMD $WORK_DIR/deploy_squid.sh $BASTION_USER@$bastion_fip:/tmp
$SSH_CMD chmod +x /tmp/deploy_squid.sh
$SSH_CMD bash -c /tmp/deploy_squid.sh

cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://${bastion_fip}:8213/
export HTTPS_PROXY=http://${bastion_fip}:8213/
export NO_PROXY="redhat.io,quay.io,redhat.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"

export http_proxy=http://${bastion_fip}:8213/
export https_proxy=http://${bastion_fip}:8213/
export no_proxy="redhat.io,quay.io,redhat.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"
EOF

echo "Bastion proxy is ready!"
