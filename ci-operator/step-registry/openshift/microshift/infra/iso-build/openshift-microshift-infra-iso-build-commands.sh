#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

cat <<EOF > /tmp/iso.sh
#!/bin/bash
set -xeuo pipefail

source /tmp/ci-functions.sh
ci_subscription_register
ci_copy_secrets "${CACHE_REGION}"

sudo dnf install -y pcp-zeroconf; sudo systemctl start pmcd; sudo systemctl start pmlogger

tar -xf /tmp/microshift.tgz -C ~ --strip-components 4

cd ~/microshift

export CI_JOB_NAME="${JOB_NAME}"
if [[ "${JOB_NAME}" =~ .*-cache.* ]] ; then
    ./test/bin/ci_phase_iso_build.sh -update_cache
else
    ./test/bin/ci_phase_iso_build.sh
fi
EOF
chmod +x /tmp/iso.sh

ci_clone_src
tar czf /tmp/microshift.tgz /go/src/github.com/openshift/microshift

scp \
    "${SHARED_DIR}/ci-functions.sh" \
    /tmp/iso.sh \
    /var/run/rhsm/subscription-manager-org \
    /var/run/rhsm/subscription-manager-act-key \
    "${CLUSTER_PROFILE_DIR}/pull-secret" \
    "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    /tmp/microshift.tgz \
    "${INSTANCE_PREFIX}:/tmp"

if [ -e /var/run/microshift-dev-access-keys/aws_access_key_id ] && \
   [ -e /var/run/microshift-dev-access-keys/aws_secret_access_key ] ; then
    scp \
        /var/run/microshift-dev-access-keys/aws_access_key_id \
        /var/run/microshift-dev-access-keys/aws_secret_access_key \
        "${INSTANCE_PREFIX}:/tmp"
fi

finalize() {
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/build-logs" "${ARTIFACT_DIR}" || true
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/nginx_error.log" "${ARTIFACT_DIR}" || true
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/nginx.log" "${ARTIFACT_DIR}" || true
}
trap 'finalize' EXIT

# Run in background to allow trapping signals before the command ends. If running in foreground
# then TERM is queued until the ssh completes. This might be too long to fit in the grace period
# and get abruptly killed, which prevents gathering logs.
ssh "${INSTANCE_PREFIX}" "/tmp/iso.sh" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
