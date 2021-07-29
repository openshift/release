#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" != "byon" ]]; then
    echo "Skipping step due to CONFIG_TYPE not being byon."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
BASTION_FIP=$(<"${SHARED_DIR}"/BASTION_FIP)

# configure the local container environment to have the correct SSH configuration
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${BASTION_USER}:x:$(id -u):0:${BASTION_USER:-centos} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi
# shellcheck disable=SC2140
SSH_ARGS="-o ConnectTimeout=10 -o "StrictHostKeyChecking=no" -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey"
SSH_CMD="ssh ${SSH_ARGS} ${BASTION_USER}@${BASTION_FIP}"
SCP_CMD="scp ${SSH_ARGS}"

>&2 echo "Collecting squid logs from 'bastionproxy-$CLUSTER_NAME'"
$SSH_CMD bash - <<EOF
mkdir -p /tmp/squid-logs
sudo cp /var/log/squid/access.log /tmp/squid-logs || true
sudo cp /var/log/squid/cache.log /tmp/squid-logs || true
sudo chown -R ${BASTION_USER}: /tmp/squid-logs || true
tar -czC "/tmp" -f "/tmp/squid-logs.tar.gz" squid-logs/
EOF
$SCP_CMD ${BASTION_USER}@${BASTION_FIP}:/tmp/squid-logs.tar.gz ${ARTIFACT_DIR}

>&2 echo "Starting the server cleanup for cluster name '$CLUSTER_NAME'"
openstack server delete "bastionproxy-$CLUSTER_NAME" || >&2 echo "Failed to delete server bastionproxy-$CLUSTER_NAME"
openstack security group delete "$CLUSTER_NAME" || >&2 echo "Failed to delete security group $CLUSTER_NAME"
openstack keypair delete "$CLUSTER_NAME" || >&2 echo "Failed to delete keypair $CLUSTER_NAME"
>&2 echo 'Cleanup done.'
