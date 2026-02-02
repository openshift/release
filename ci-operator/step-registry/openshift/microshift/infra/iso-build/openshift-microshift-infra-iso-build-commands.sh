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

download_microshift_scripts
"\${DNF_RETRY}" "install" "pcp-zeroconf jq sos"
ci_copy_secrets "${CACHE_REGION}"

sudo systemctl start pmcd
sudo systemctl start pmlogger

tar -xf /tmp/microshift.tgz -C ~ --strip-components 4
cd ~/microshift

export CI_JOB_NAME="${JOB_NAME}"
export GITHUB_TOKEN="\$(cat /tmp/token-git 2>/dev/null || echo '')"
if [[ "${JOB_NAME}" =~ .*-cache.* ]] ; then
    ./test/bin/ci_phase_iso_build.sh -update_cache
else
    ./test/bin/ci_phase_iso_build.sh
fi
EOF
chmod +x /tmp/iso.sh

# To clone a private branch for testing cross-repository source changes, comment
# out the 'ci_clone_src' function call and add the following commands instead.
#
# GUSR=myuser
# GBRN=mybranch
# git clone "https://github.com/${GUSR}/microshift.git" -b "${GBRN}" /go/src/github.com/openshift/microshift
#
ci_clone_src

download_brew_rpms() {
    # See BREW_RPM_SOURCE variable definition in test/bin/common.sh
    src_path="/go/src/github.com/openshift/microshift"
    out_path="${src_path}/_output/test-images/brew-rpms"
    pushd "${src_path}" &>/dev/null

    # Check if the manage_brew_rpms.sh script exists.
    # Do not fail to support older branches (release-4.18 and previous).
    if [ ! -e ./test/bin/manage_brew_rpms.sh ] ; then
        echo "./test/bin/manage_brew_rpms.sh not found - RPM download from brew is not possible"
        return 0
    fi

    # Check if brew hub site is accessible
    bash -x ./scripts/fetch_tools.sh brew
    if ! bash -x ./test/bin/manage_brew_rpms.sh access; then
        echo "ERROR: Brew Hub site is not accessible"
        return 1
    fi

    # Download the latest RPMs from brew: latest release (ec, rc and zstream), nightly, Y-1 zstream and Y-2 zstream
    y_version="$(cut -d'.' -f2 "${src_path}/Makefile.version.$(uname -m).var")"
    bash -x ./test/bin/manage_brew_rpms.sh download "4.${y_version}" "${out_path}" "ec" || echo "WARNING: Failed to download EC RPMs for 4.${y_version}"
    bash -x ./test/bin/manage_brew_rpms.sh download "4.${y_version}" "${out_path}" "rc" || echo "WARNING: Failed to download RC RPMs for 4.${y_version}"
    bash -x ./test/bin/manage_brew_rpms.sh download "4.${y_version}" "${out_path}" "zstream" || echo "WARNING: Failed to download zstream RPMs for 4.${y_version}"
    bash -x ./test/bin/manage_brew_rpms.sh download "4.${y_version}" "${out_path}" "nightly" || echo "WARNING: Failed to download nightly RPMs for 4.${y_version}"
    bash -x ./test/bin/manage_brew_rpms.sh download "4.$((${y_version} - 1))" "${out_path}" "zstream" || echo "WARNING: Failed to download zstream RPMs for 4.$((${y_version} - 1))"
    bash -x ./test/bin/manage_brew_rpms.sh download "4.$((${y_version} - 2))" "${out_path}" "zstream" || ( echo "WARNING: Failed to download zstream RPMs for 4.$((${y_version} - 2))" && return 1 )

    popd &>/dev/null
    return 0
}

# Attempt downloading latest MicroShift RPMs from brew.
# This requires VPN access, which is only enabled for the cache jobs.
if [[ "${JOB_NAME}" =~ .*-cache.* ]] ; then
    download_brew_rpms
fi

# Archive the sources, potentially including MicroShift RPMs from brew
tar czf /tmp/microshift.tgz /go/src/github.com/openshift/microshift

scp \
    "${SHARED_DIR}/ci-functions.sh" \
    /tmp/iso.sh \
    /var/run/rhsm/subscription-manager-org \
    /var/run/rhsm/subscription-manager-act-key \
    /var/run/vault/tests-private-account/token-git \
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

if [ -e /var/run/microshift-dev-access-keys/registry.stage.redhat.io ] ; then
    scp /var/run/microshift-dev-access-keys/registry.stage.redhat.io \
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
