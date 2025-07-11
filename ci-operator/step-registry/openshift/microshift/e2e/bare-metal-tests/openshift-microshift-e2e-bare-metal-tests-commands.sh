#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue

cat <<EOF > /tmp/prepare.sh
#!/bin/bash
set -xeuo pipefail

source /tmp/ci-functions.sh
ci_subscription_register

download_microshift_scripts
"\${DNF_RETRY}" "install" "jq git"
ci_copy_secrets "${CACHE_REGION}"

tar -xf /tmp/microshift.tgz -C ~ --strip-components 4
EOF
chmod +x /tmp/prepare.sh

ci_clone_src
tar czf /tmp/microshift.tgz /go/src/github.com/openshift/microshift

scp \
  "${SHARED_DIR}/ci-functions.sh" \
  /tmp/prepare.sh \
  /var/run/rhsm/subscription-manager-org \
  /var/run/rhsm/subscription-manager-act-key \
  /var/run/microshift-dev-access-keys/aws_access_key_id \
  /var/run/microshift-dev-access-keys/aws_secret_access_key \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  /tmp/microshift.tgz \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/prepare.sh"

# nvidia-device-plugin scripts live primarily in the main branch of microshift.
# If the $SUITE is nvidia-device-plugin, we clone the main branch of microshift and copy the scripts to right version of MicroShift's repo.
if [[ "${SUITE}" == "nvidia-device-plugin" ]]; then
    ssh "${INSTANCE_PREFIX}" \
        "git clone --filter=blob:none --no-checkout --depth 1 --sparse https://github.com/openshift/microshift.git /home/${HOST_USER}/microshift-main && \
            cd /home/${HOST_USER}/microshift-main && \
            git sparse-checkout add ./scripts/ci-nvidia-device-plugin/ && \
            git checkout main"

    ssh "${INSTANCE_PREFIX}" \
        "cp -r /home/${HOST_USER}/microshift-main/scripts/ci-nvidia-device-plugin /home/${HOST_USER}/microshift/scripts/ci-nvidia-device-plugin/"

    if [[ "${JOB_NAME}" == *"release-4.14"* || "${JOB_NAME}" == *"release-4.15"* ]]; then
        # MicroShift 4.14 and 4.15 healthcheck scripts do not detect missing LVM setup and always expect CSI to be present. For those version, we setup LVM.
        # Step infra-lvm-install cannot be used because bare-metal-tests step is shared with bare metal instances which are not set up for LVM (missing partitions).

        # Sometimes, devices are in different order and nvme1 stores OS while nvme0 should hold LVM for topolvm.
        # If /dev/nvme0 is already partitioned (operating system), then use nvme1 for lvm.
        # If `partx /dev/nvme0n1` fails (rc=1), it couldn't read partition table, so it's the one to use for lvm.
        if ssh "${INSTANCE_PREFIX}" "sudo partx /dev/nvme0n1"; then
            device="/dev/nvme1n1"
        else
            device="/dev/nvme0n1"
        fi
        ssh "${INSTANCE_PREFIX}" "lsblk ; sudo dnf install -y lvm2 && sudo pvcreate ${device} && sudo vgcreate rhel ${device}"
    fi
fi

setup_ok=true
if ! ssh "${INSTANCE_PREFIX}" "bash -x \${HOME}/microshift/scripts/ci-${SUITE}/1-setup.sh"; then
    setup_ok=false
fi
# Always try to get the artifacts, even if the setup failed
scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/artifacts/*" "${ARTIFACT_DIR}" || true

if ! "${setup_ok}"; then
    exit 1
fi

boot_id=$(ssh "${INSTANCE_PREFIX}" 'cat /proc/sys/kernel/random/boot_id')
ssh "${INSTANCE_PREFIX}" "bash -x \${HOME}/microshift/scripts/ci-${SUITE}/2-reboot.sh" || true

: Waiting for the host to be up
boot_timeout=$(( 20 * 60  ))
start_time=$(date +%s)
while true ; do
    new_boot_id=$(ssh -oConnectTimeout=10 -oBatchMode=yes -oStrictHostKeyChecking=accept-new "${INSTANCE_PREFIX}" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)

    if [[ -n "${new_boot_id}" && "${boot_id}" != "${new_boot_id}" ]]; then
        time_to_up=$(( $(date +%s) - start_time ))
        echo "Host is up after $(( time_to_up / 60 ))m $(( time_to_up % 60 ))s."
        break
    fi

    if [ $(( $(date +%s) - start_time )) -gt "${boot_timeout}" ]; then
        echo "ERROR: Waited too long for the host to boot."
        exit 1
    fi

    sleep 30
done

# Example of $CLONEREFS_OPTIONS:
# {
#     "src_root": "/go",
#     "log": "/dev/null",
#     "git_user_name": "ci-robot",
#     "git_user_email": "ci-robot@openshift.io",
#     "refs": [
#         {
#             "org": "openshift",
#             "repo": "release",
#             "base_ref": "master",
#             "base_sha": "2bab4e1b820127733105b1d170c47fd71ca0b8f1",
#             "pulls": [
#                 {
#                     "number": 55565,
#                     "author": "pmtk",
#                     "sha": "2154ef6d003515dfb93909c9e404acd0c775c611",
#                     "link": "https://github.com/openshift/release/pull/55565"
#                 }
#             ]
#         },
#         {
#             "org": "openshift",
#             "repo": "microshift",
#             "base_ref": "main",
#             "workdir": true
#         }
#     ],
#     "fail": true
# }
BRANCH=$(echo $CLONEREFS_OPTIONS | jq -r '.refs[] | select(.repo=="microshift") | .base_ref')
if [[ "${BRANCH}" == "" ]]; then
    echo "BRANCH turned out to be empty - investigate"
    env
    exit 1
fi

ssh "${INSTANCE_PREFIX}" "JOB_TYPE=${JOB_TYPE} BRANCH=${BRANCH} bash -x \$HOME/microshift/scripts/ci-${SUITE}/3-test.sh"
