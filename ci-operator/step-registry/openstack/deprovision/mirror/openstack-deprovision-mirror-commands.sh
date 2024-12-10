#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "$CONFIG_TYPE" != *"singlestackv6"* ]]; then
    echo "Skipping step due to CONFIG_TYPE not being singlestackv6."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)

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

if [[ -f ${SHARED_DIR}"/MIRROR_SSH_IP" ]]; then
    mirror_ip=$(<"${SHARED_DIR}"/MIRROR_SSH_IP)
    ssh_via_proxy() {
        local command=$1
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey -o ProxyCommand="nc --proxy-auth ${proxy_credentials} --proxy ${proxy_host}:3128 %h %p" $BASTION_USER@$mirror_ip "$command"
    }

    scp_via_proxy() {
        local src=$1
        local dest=$2
        scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey -o ProxyCommand="nc --proxy-auth ${proxy_credentials} --proxy ${proxy_host}:3128 %h %p" $src $dest
    }
    ssh_via_proxy bash - <<EOF
    mkdir -p /tmp/mirror-logs
    sudo podman logs registry > /tmp/mirror-logs/registry.log || true
    sudo chown -R ${BASTION_USER}: /tmp/mirror-logs || true
    tar -czC "/tmp" -f "/tmp/mirror-logs.tar.gz" mirror-logs/
EOF
    scp_via_proxy ${BASTION_USER}@${mirror_ip}:/tmp/mirror-logs.tar.gz ${ARTIFACT_DIR}
    echo "Mirror logs collected in ${ARTIFACT_DIR}/mirror-logs.tar.gz"
fi

>&2 echo "Starting the server cleanup for cluster '$CLUSTER_NAME'"
openstack server delete --wait "mirror-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete server mirror-${CLUSTER_NAME}-${CONFIG_TYPE}"
openstack security group delete "mirror-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete security group mirror-${CLUSTER_NAME}-${CONFIG_TYPE}"
openstack keypair delete "mirror-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete keypair mirror-${CLUSTER_NAME}-${CONFIG_TYPE}"
>&2 echo 'Cleanup done.'
