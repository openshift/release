#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
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

cat << EOF2 > /tmp/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF2

cat <<EOF > /tmp/install.sh
#!/bin/bash
set -xeuo pipefail
sudo dnf install -y git
if ! sudo subscription-manager status >&/dev/null; then
    sudo subscription-manager register \
        --org="\$(cat /tmp/subscription-manager-org)" \
        --activationkey="\$(cat /tmp/subscription-manager-act-key)"
fi

export PULL_SECRET="\${HOME}/.pull-secret.json"
cp /tmp/pull-secret "\${PULL_SECRET}"

sudo mkdir -p /etc/microshift
sudo cp /tmp/config.yaml /etc/microshift/config.yaml

git clone https://github.com/openshift/microshift -b ${BRANCH} \${HOME}/microshift
cd \${HOME}/microshift
chmod 0755 \${HOME}
bash -x ./scripts/devenv-builder/configure-vm.sh --force-firewall "\${PULL_SECRET}"
EOF
chmod +x /tmp/install.sh

scp \
  /tmp/install.sh \
  /tmp/config.yaml \
  /var/run/rhsm/subscription-manager-org \
  /var/run/rhsm/subscription-manager-act-key \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/install.sh"