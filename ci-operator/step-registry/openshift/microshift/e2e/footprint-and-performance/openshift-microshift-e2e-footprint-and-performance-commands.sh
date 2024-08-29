#!/usr/bin/env bash

set -xeuo pipefail

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

cat << 'EOF' > /tmp/prepare.sh
#!/bin/bash
set -xeuo pipefail

if ! sudo subscription-manager status >&/dev/null; then
    sudo subscription-manager register \
        --org="$(cat /tmp/subscription-manager-org)" \
        --activationkey="$(cat /tmp/subscription-manager-act-key)"
fi

cp /tmp/pull-secret "${HOME}/.pull-secret.json"

mkdir -p -m 0700 ${HOME}/.aws/

# Profile configuration
cat <<EOF2 >> ${HOME}/.aws/config
[microshift-ci]
region = us-west-2
output = json
EOF2

# Profile credentials
cat <<EOF2 >>${HOME}/.aws/credentials
[microshift-ci]
aws_access_key_id = $(cat /tmp/aws_access_key_id)
aws_secret_access_key = $(cat /tmp/aws_secret_access_key)
EOF2

# Permissions and environment settings
chmod -R go-rwx ${HOME}/.aws/

chmod 0755 ~
tar -xf /tmp/microshift.tgz -C ~ --strip-components 4
EOF
chmod +x /tmp/prepare.sh

tar czf /tmp/microshift.tgz /go/src/github.com/openshift/microshift
scp \
  /tmp/prepare.sh \
  /var/run/rhsm/subscription-manager-org \
  /var/run/rhsm/subscription-manager-act-key \
  /var/run/microshift-dev-access-keys/aws_access_key_id \
  /var/run/microshift-dev-access-keys/aws_secret_access_key \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  /tmp/microshift.tgz \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/prepare.sh"

ssh "${INSTANCE_PREFIX}" 'bash -x $HOME/microshift/scripts/ci-footprint-and-performance/1-setup.sh'
boot_id=$(ssh "${INSTANCE_PREFIX}" 'cat /proc/sys/kernel/random/boot_id')
ssh "${INSTANCE_PREFIX}" 'bash -x $HOME/microshift/scripts/ci-footprint-and-performance/2-reboot.sh' || true

: Waiting for the host to be up
boot_timeout=$(( 20 * 60  ))
start_time=$(date +%s)
while true ; do
    if ssh -oConnectTimeout=10 -oBatchMode=yes -oStrictHostKeyChecking=accept-new "${INSTANCE_PREFIX}" "true" &>/dev/null; then
        new_boot_id=$(ssh "${INSTANCE_PREFIX}" 'cat /proc/sys/kernel/random/boot_id')
        if [[ "${boot_id}" != "${new_boot_id}" ]]; then
            time_to_up=$(( $(date +%s) - start_time ))
            echo "Host is up after $(( time_to_up / 60 ))m $(( time_to_up % 60 ))s."
            break
        fi
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

ssh "${INSTANCE_PREFIX}" "JOB_TYPE=${JOB_TYPE} BRANCH=${BRANCH} bash -x \$HOME/microshift//scripts/ci-footprint-and-performance/3-test.sh"
