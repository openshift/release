#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# collect logs from the proxy here
if [ -f "${SHARED_DIR}/proxyip" ]; then
  proxy_ip="$(cat "${SHARED_DIR}/proxyip")"

  ssh_user="core"
  if [ -s "${SHARED_DIR}/bastion_ssh_user" ]; then
    ssh_user="$(< "${SHARED_DIR}/bastion_ssh_user" )"
  fi

  if ! whoami &> /dev/null; then
    if [ -w /etc/passwd ]; then
      echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
  fi
  eval "$(ssh-agent)"
  ssh-add "${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  ssh -A -o PreferredAuthentications=publickey -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null "${ssh_user}@${proxy_ip}" 'journalctl -u squid' > "${ARTIFACT_DIR}/squid.service"
fi