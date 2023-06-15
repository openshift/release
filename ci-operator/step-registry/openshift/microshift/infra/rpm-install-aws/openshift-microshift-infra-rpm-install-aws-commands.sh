#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"
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

cat <<EOF > /tmp/install.sh
#!/bin/bash
set -xeuo pipefail

rpm --rebuilddb
dnf install subscription-manager -y

subscription-manager register \
  --org="$(cat /var/run/rhsm/subscription-manager-org)" \
  --activationkey="$(cat /var/run/rhsm/subscription-manager-act-key)"

mkdir -p /etc/microshift
cat << EOF2 > /etc/microshift/config.yaml
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF2

useradd -m -G wheel microshift
echo -e 'microshift\tALL=(ALL)\tNOPASSWD: ALL' > /etc/sudoers.d/microshift

OPTS=""
if grep "\-\-no-build-deps" /tmp/configure-vm.sh; then
  OPTS="--no-build-deps --force-firewall"
fi
cd /home/microshift && sudo -nu microshift bash -x /tmp/configure-vm.sh --no-build \${OPTS} /tmp/pull-secret

mkdir -p /tmp/rpms
tar -xhvf /tmp/rpms.tar --strip-components 2 -C /tmp/rpms
dnf localinstall -y \$(find /tmp/rpms/ -iname "*\$(uname -p)*" -or -iname '*noarch*')

# 4.12 and 4.13 don't set up cri-o pull secret in case of --no-build
if [ ! -e /etc/crio/openshift-pull-secret ]; then
    cp /tmp/pull-secret /etc/crio/openshift-pull-secret
    chmod 600 /etc/crio/openshift-pull-secret
fi
EOF
chmod +x /tmp/install.sh

scp \
  /rpms.tar \
  /tmp/install.sh \
  /microshift/scripts/devenv-builder/configure-vm.sh \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "sudo /tmp/install.sh"

echo 1 >> ${SHARED_DIR}/num_vms
echo ${HOST_USER} >> ${SHARED_DIR}/user_0
echo 22 >> ${SHARED_DIR}/ssh_port_0
