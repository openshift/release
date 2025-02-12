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
openstack security group rule create --ingress --protocol tcp --dst-port 22 --description "${CLUSTER_NAME} SSH" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol tcp --ethertype IPv6 --remote-ip "::/0" --dst-port 8443 --description "${CLUSTER_NAME} mirror registry" "$sg_id" >/dev/null
>&2 echo "Created necessary security group rules in ${sg_id}"

server_params="--network $CONTROL_PLANE_NETWORK --image $BASTION_IMAGE --flavor $BASTION_FLAVOR \
  --security-group $sg_id --key-name mirror-${CLUSTER_NAME}-${CONFIG_TYPE} \
  --block-device source_type=blank,destination_type=volume,volume_size=70,delete_on_termination=true"

server_id="$(openstack server create --wait -f value -c id $server_params \
		"mirror-$CLUSTER_NAME-${CONFIG_TYPE}")"
>&2 echo "Created nova server mirror-${CLUSTER_NAME}-${CONFIG_TYPE}: ${server_id}"

IPV4_REGEX="((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])"
IPV6_REGEX="(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))"
mirror_ipv4="$(openstack server show -f value -c addresses mirror-$CLUSTER_NAME-${CONFIG_TYPE} | grep -oE $IPV4_REGEX)"
mirror_ipv6="$(openstack server show -f value -c addresses mirror-$CLUSTER_NAME-${CONFIG_TYPE} | grep -oE $IPV6_REGEX)"

# configure the local container environment to have the correct SSH configuration
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${BASTION_USER}:x:$(id -u):0:${BASTION_USER} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

if [[ -f "${SHARED_DIR}/squid-credentials.txt" ]]; then
   proxy_host=$(yq -r ".clouds.${OS_CLOUD}.auth.auth_url" "$OS_CLIENT_CONFIG_FILE" | cut -d/ -f3 | cut -d: -f1)
   proxy_credentials=$(<"${SHARED_DIR}/squid-credentials.txt")
   echo "Using proxy $proxy_host for SSH connection"
else
  echo "Missing squid-credentials.txt file"
  exit 1
fi

ssh_via_proxy() {
    local command=$1
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey -o ProxyCommand="nc --proxy-auth ${proxy_credentials} --proxy ${proxy_host}:3128 %h %p" $BASTION_USER@$mirror_ipv4 "$command"
}

scp_via_proxy() {
    local src=$1
    local dest=$2
    scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey -o ProxyCommand="nc --proxy-auth ${proxy_credentials} --proxy ${proxy_host}:3128 %h %p" $src $dest
}

if ! retry 60 5 ssh_via_proxy "uname -a"; then
		echo "ERROR: Bastion proxy is not reachable via $mirror_ipv4 - check logs:"
    openstack console log show ${server_id}
		exit 1
fi
MIRROR_REGISTRY_CREDENTIALS=$(<"/var/run/vault/mirror-registry/registry_creds")
USER="foo"
PASSWORD="foo"
#USER="$(echo $MIRROR_REGISTRY_CREDENTIALS | cut -d':' -f1 )"
#PASSWORD="$(echo $MIRROR_REGISTRY_CREDENTIALS | cut -d':' -f2 )"

MIRROR_REGISTRY_DNS_NAME="mirror-registry.${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "Deploying the mirror registry"
>&2 cat << EOF > $WORK_DIR/deploy_mirror.sh
#!/usr/bin/env bash
set -e
sudo mkfs.xfs /dev/vdc
sudo mkdir -p /opt/registry/{auth,certs,data}
sudo mount /dev/vdc /opt/registry/data
openssl req -newkey rsa:4096 -nodes -sha256 -keyout domain.key -x509 -days 1 -subj "/CN=mirror-$CLUSTER_NAME-${CONFIG_TYPE}" -addext "subjectAltName=DNS:$MIRROR_REGISTRY_DNS_NAME,DNS:mirror-$CLUSTER_NAME-${CONFIG_TYPE}" -out domain.crt
sudo cp domain.crt /opt/registry/certs/domain.crt
sudo cp domain.key /opt/registry/certs/domain.key
sudo cp /opt/registry/certs/domain.crt /etc/pki/ca-trust/source/anchors/domain.crt
sudo update-ca-trust
sudo dnf install -y podman
curl -L -o mirror-registry.tar.gz https://mirror.openshift.com/pub/cgw/mirror-registry/latest/mirror-registry-amd64.tar.gz --retry 12
tar -xzvf mirror-registry.tar.gz
echo "Running the mirror registry"
./mirror-registry install --sslCert domain.crt --sslKey domain.key --quayHostname mirror-$CLUSTER_NAME-${CONFIG_TYPE} --initPassword ${PASSWORD} --initUser ${USER} -v
echo "Finished the mirror registry"
podman login -u ${USER} -p ${PASSWORD} https://mirror-$CLUSTER_NAME-${CONFIG_TYPE}:8443"
EOF

scp_via_proxy $WORK_DIR/deploy_mirror.sh $BASTION_USER@$mirror_ipv4:/tmp
ssh_via_proxy "chmod +x /tmp/deploy_mirror.sh"
ssh_via_proxy "bash -c /tmp/deploy_mirror.sh"

echo "Finished running mirror"

echo "${MIRROR_REGISTRY_DNS_NAME}:8443" >"${SHARED_DIR}/mirror_registry_url"
scp_via_proxy $BASTION_USER@$mirror_ipv4:/opt/registry/certs/domain.crt ${SHARED_DIR}/additional_trust_bundle
echo $mirror_ipv4 > "${SHARED_DIR}/MIRROR_SSH_IP"
echo $mirror_ipv6 > "${SHARED_DIR}/MIRROR_REGISTRY_IP"

echo "Mirror is ready!"
