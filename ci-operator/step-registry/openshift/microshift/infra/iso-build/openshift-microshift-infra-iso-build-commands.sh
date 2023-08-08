#!/bin/bash
set -xeuo pipefail

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

cat <<EOF > /tmp/iso.sh
#!/bin/bash
set -xeuo pipefail

if ! sudo subscription-manager status >&/dev/null; then
    sudo subscription-manager register \
        --org="\$(cat /tmp/subscription-manager-org)" \
        --activationkey="\$(cat /tmp/subscription-manager-act-key)"
fi

chmod 0755 ~
tar -xf /tmp/microshift.tgz -C ~

cp /tmp/ssh-publickey ~/.ssh/id_rsa.pub
cp /tmp/ssh-privatekey ~/.ssh/id_rsa
chmod 0400 ~/.ssh/id_rsa*

# Set up the pull secret in the expected location
export PULL_SECRET="\${HOME}/.pull-secret.json"
cp /tmp/pull-secret "\${PULL_SECRET}"

cd ~/microshift

./test/bin/ci_phase_iso_build.sh
EOF
chmod +x /tmp/iso.sh

tar czf /tmp/microshift.tgz /microshift

scp \
    /tmp/iso.sh \
    /var/run/rhsm/subscription-manager-org \
    /var/run/rhsm/subscription-manager-act-key \
    "${CLUSTER_PROFILE_DIR}/pull-secret" \
    "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    /tmp/microshift.tgz \
    "${INSTANCE_PREFIX}:/tmp"

trap 'scp -r ${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/build-logs ${ARTIFACT_DIR}' EXIT
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

ssh "${INSTANCE_PREFIX}" "/tmp/iso.sh" &
wait
