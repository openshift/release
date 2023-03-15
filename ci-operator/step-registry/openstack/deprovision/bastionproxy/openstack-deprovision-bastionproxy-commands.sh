#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "$CONFIG_TYPE" != *"proxy"* ]]; then
    echo "Skipping step due to CONFIG_TYPE not being proxy."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
PROXY_PORT_ID=$(<"${SHARED_DIR}"/PROXY_PORT_ID)

if [[ -f "${SHARED_DIR}/squid-credentials.txt" ]]; then
    echo "Proxy is permanent, nothing to cleanup"
    exit 0
fi

>&2 echo "Starting the server cleanup for cluster '$CLUSTER_NAME'"

if [[ -f ${SHARED_DIR}"/BASTION_FIP" ]]; then 
  BASTION_FIP=$(<"${SHARED_DIR}"/BASTION_FIP)

  # configure the local container environment to have the correct SSH configuration
  if ! whoami &> /dev/null; then
      if [[ -w /etc/passwd ]]; then
          echo "${BASTION_USER:-cloud-user}:x:$(id -u):0:${BASTION_USER:-cloud-user} user:${HOME}:/sbin/nologin" >> /etc/passwd
      fi
  fi
  # shellcheck disable=SC2140
  SSH_ARGS="-o ConnectTimeout=10 -o "StrictHostKeyChecking=no" -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  SSH_CMD="ssh ${SSH_ARGS} ${BASTION_USER}@${BASTION_FIP}"
  SCP_CMD="scp ${SSH_ARGS}"
  
  >&2 echo "Collecting squid logs from 'bastionproxy-$CLUSTER_NAME'"
  $SSH_CMD bash - <<EOF
  mkdir -p /tmp/bastion-logs
  sudo cp /var/log/squid/access.log /tmp/bastion-logs/squid-access.log || true
  sudo cp /var/log/squid/cache.log /tmp/bastion-logs/squid-cache.log || true
  if [ -f /etc/haproxy/haproxy.cfg ]; then
    sudo journalctl -u haproxy --no-pager > /tmp/bastion-logs/haproxy.log
  fi
  if [ -f /etc/systemd/system/vips.service ]; then
    sudo journalctl -u vips --no-pager > /tmp/bastion-logs/vips.log
  fi
  ip a > /tmp/bastion-logs/ip-a.txt
  ip r > /tmp/bastion-logs/ip-r.txt
  sudo chown -R ${BASTION_USER}: /tmp/bastion-logs || true
  tar -czC "/tmp" -f "/tmp/bastion-logs.tar.gz" bastion-logs/
EOF
  $SCP_CMD ${BASTION_USER}@${BASTION_FIP}:/tmp/bastion-logs.tar.gz ${ARTIFACT_DIR}
  echo "Bastion proxy logs collected in ${ARTIFACT_DIR}/bastion-logs.tar.gz"

  openstack floating ip delete ${BASTION_FIP} || >&2 echo "Failed to delete floating IP ${BASTION_FIP}"
fi

openstack server delete --wait "bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete server bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}"
openstack port delete $PROXY_PORT_ID || >&2 echo "Failed to delete proxy port ${PROXY_PORT_ID}"
openstack security group delete "bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete security group bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}"
openstack keypair delete "bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}" || >&2 echo "Failed to delete keypair bastionproxy-${CLUSTER_NAME}-${CONFIG_TYPE}"
>&2 echo 'Cleanup done.'
