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

cat << EOF > /tmp/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF

cat <<EOF > /tmp/install.sh
#!/bin/bash
set -xeuo pipefail

sudo subscription-manager register \
  --org="$(cat /var/run/rhsm/subscription-manager-org)" \
  --activationkey="$(cat /var/run/rhsm/subscription-manager-act-key)"

sudo mkdir -p /etc/microshift
sudo mv /tmp/config.yaml /etc/microshift/config.yaml
tar -xf /tmp/microshift.tgz -C ~ --strip-components 4
cd ~/microshift
./scripts/devenv-builder/configure-vm.sh --force-firewall --no-build /tmp/pull-secret
sudo dnf clean all -y
make rpm
sudo dnf localinstall -y ./_output/rpmbuild/RPMS/*/*.rpm
sudo systemctl enable --now crio
sudo systemctl enable --now microshift
EOF
chmod +x /tmp/install.sh

tar czf /tmp/microshift.tgz /go/src/github.com/openshift/microshift

scp \
  /tmp/install.sh \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  /tmp/microshift.tgz \
  /tmp/config.yaml \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/install.sh"
