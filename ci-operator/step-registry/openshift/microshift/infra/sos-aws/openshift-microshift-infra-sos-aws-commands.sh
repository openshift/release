#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}/public_address")"
HOST_USER="$(cat "${SHARED_DIR}/ssh_user")"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User ${HOST_USER}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

ssh "${INSTANCE_PREFIX}" <<'EOF'
  set -x
  if ! hash sos ; then
    sudo touch /tmp/sosreport-command-does-not-exist
    exit 0
  fi

  plugin_list="container,network"
  if ! sudo sos report --list-plugins | grep 'microshift.*inactive' ; then
    plugin_list+=",microshift"
  fi

  if sudo sos report --batch --all-logs --tmp-dir /tmp -p ${plugin_list} -o logs ; then
    sudo chmod +r /tmp/sosreport-*
  else
    sudo touch /tmp/sosreport-command-failed
  fi
EOF
scp "${INSTANCE_PREFIX}":/tmp/sosreport-* "${ARTIFACT_DIR}" || true
