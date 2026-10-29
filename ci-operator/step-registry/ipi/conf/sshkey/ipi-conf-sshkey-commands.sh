#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

if [[ -z "${SSH_KEY_TYPE_LIST}" ]]; then
    echo "ERROR: not specify any ssh key types via ENV 'SSH_KEY_TYPE_LIST'!"
    exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
CONFIG_PATCH="/tmp/install-config-sshkey.patch"
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

cat > "${CONFIG_PATCH}" << EOF
sshKey: |
  ${SSH_PUB_KEY}
EOF

for key_type in ${SSH_KEY_TYPE_LIST}; do
    key_file="/tmp/key-${key_type}"
    option=""
    if [[ "${key_type}" == "ecdsa" ]]; then
        option="-b 521"
    fi
    echo "Generating ssh key with type ${key_type}..."
    ssh-keygen -t ${key_type} ${option} -N '' -f "${key_file}"
    # save private sshkey for post check
    cp "${key_file}" "${SHARED_DIR}"
    cat >> "${CONFIG_PATCH}" << EOF
  $(<${key_file}.pub)
EOF
done

# apply patch to install-config.yaml
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

#for debug
cat "${CONFIG_PATCH}"
