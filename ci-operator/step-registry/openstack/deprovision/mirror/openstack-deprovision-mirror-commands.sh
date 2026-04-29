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
   echo "Using proxy $proxy_host for SSH connection to mirror"
   USE_PROXY=true
else
  echo "No squid-credentials.txt found, using direct SSH connection to mirror"
  USE_PROXY=false
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

    ssh_direct() {
        local command=$1
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey $BASTION_USER@$mirror_ip "$command"
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

    ssh_mirror bash - <<EOF
    mkdir -p /tmp/mirror-logs
    sudo podman logs registry > /tmp/mirror-logs/registry.log || true
    sudo chown -R ${BASTION_USER}: /tmp/mirror-logs || true
    tar -czC "/tmp" -f "/tmp/mirror-logs.tar.gz" mirror-logs/
EOF
    scp_mirror ${BASTION_USER}@${mirror_ip}:/tmp/mirror-logs.tar.gz ${ARTIFACT_DIR}
    echo "Mirror logs collected in ${ARTIFACT_DIR}/mirror-logs.tar.gz"
fi

>&2 echo "Starting the server cleanup for cluster '$CLUSTER_NAME'"
openstack server delete --wait "mirror-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete server mirror-${CLUSTER_NAME}-${CONFIG_TYPE}"

# Delete floating IP if it was created
if [[ -f "${SHARED_DIR}/MIRROR_FIP" ]]; then
  mirror_fip=$(<"${SHARED_DIR}/MIRROR_FIP")
  openstack floating ip delete "${mirror_fip}" || >&2 echo "Failed to delete floating IP ${mirror_fip}"
fi

openstack security group delete "mirror-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete security group mirror-${CLUSTER_NAME}-${CONFIG_TYPE}"
openstack keypair delete "mirror-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete keypair mirror-${CLUSTER_NAME}-${CONFIG_TYPE}"
>&2 echo 'Cleanup done.'
