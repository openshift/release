#!/bin/bash
set -xeuo pipefail
export PS4='+ $(date "+%T.%N") \011'

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

sudo dnf install -y pcp-zeroconf; sudo systemctl start pmcd; sudo systemctl start pmlogger

chmod 0755 ~
tar -xf /tmp/microshift.tgz -C ~ --strip-components 4

cp /tmp/ssh-publickey ~/.ssh/id_rsa.pub
cp /tmp/ssh-privatekey ~/.ssh/id_rsa
chmod 0400 ~/.ssh/id_rsa*

# Set up the pull secret in the expected location
export PULL_SECRET="\${HOME}/.pull-secret.json"
cp /tmp/pull-secret "\${PULL_SECRET}"

cd ~/microshift

export CI_JOB_NAME="${JOB_NAME}"
./test/bin/ci_phase_iso_build.sh
EOF
chmod +x /tmp/iso.sh

tar czf /tmp/microshift.tgz /go/src/github.com/openshift/microshift

scp \
    /tmp/iso.sh \
    /var/run/rhsm/subscription-manager-org \
    /var/run/rhsm/subscription-manager-act-key \
    "${CLUSTER_PROFILE_DIR}/pull-secret" \
    "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    /tmp/microshift.tgz \
    "${INSTANCE_PREFIX}:/tmp"

finalize() {
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/build-logs" ${ARTIFACT_DIR}
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/nginx_error.log" "${ARTIFACT_DIR}" || true
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/nginx.log" "${ARTIFACT_DIR}" || true
}
trap 'finalize' EXIT

# Call wait regardless of the outcome of the kill command, in case some of the children are finished
# by the time we try to kill them. There is only 1 child now, but this is generic enough to allow N.
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} || true; wait; fi' TERM

# Run in background to allow trapping signals before the command ends. If running in foreground
# then TERM is queued until the ssh completes. This might be too long to fit in the grace period
# and get abruptly killed, which prevents gathering logs.
ssh "${INSTANCE_PREFIX}" "/tmp/iso.sh" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
