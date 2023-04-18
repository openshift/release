#!/bin/bash

set -xu

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${INSTANCE_PREFIX}
  User ${HOST_USER}
  HostName ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

cat >"${HOME}"/build-iso.sh <<'EOF'
#!/bin/bash
set -xuo pipefail

chmod 0777 ~
dnf install -y git
git clone https://github.com/openshift/microshift /tmp/microshift
cd /tmp/microshift
mkdir -p _output/rpmbuild/RPMS
tar xf /tmp/rpms.tar -C /tmp/microshift/_output/rpmbuild/RPMS
find /tmp/microshift/_output/rpmbuild/RPMS -iname "*aarch64*" -exec rm -f {} \;
./scripts/image-builder/configure.sh
./scripts/image-builder/build.sh -pull_secret_file /tmp/pull-secret
EOF
chmod +x "${HOME}"/build-iso.sh

scp "${HOME}"/build-iso.sh "${INSTANCE_PREFIX}":~/build-iso.sh
scp ${CLUSTER_PROFILE_DIR}/pull-secret "${INSTANCE_PREFIX}":/tmp/pull-secret
scp /rpms.tar "${INSTANCE_PREFIX}":/tmp

ssh "${INSTANCE_PREFIX}" 'sudo ~/build-iso.sh'
scp "${INSTANCE_PREFIX}":~/*.tar ${ARTIFACT_DIR}/
