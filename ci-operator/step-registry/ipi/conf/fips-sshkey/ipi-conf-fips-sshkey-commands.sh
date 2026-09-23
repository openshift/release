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
CONFIG_PATCH="/tmp/install-config-fips-sshkey.patch"

# Disable tracing while handling SSH keys to avoid leaking key material in logs
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

# Replace the cluster-profile sshKey with FIPS-compatible keys only. Ed25519 keys
# from the cluster profile are rejected by openshift-install when fips: true.
cat > "${CONFIG_PATCH}" << EOF
sshKey: |
EOF

for key_type in ${SSH_KEY_TYPE_LIST}; do
    key_file="/tmp/key-${key_type}"
    keygen_options=()
    case "${key_type}" in
        ecdsa)
            keygen_options=(-b 521)
            ;;
        rsa)
            keygen_options=(-b 4096)
            ;;
        *)
            echo "ERROR: unsupported FIPS SSH key type '${key_type}'; use ecdsa or rsa"
            exit 1
            ;;
    esac
    ssh-keygen -q -t "${key_type}" "${keygen_options[@]}" -N '' -f "${key_file}"
    cp "${key_file}" "${SHARED_DIR}/"
    cat >> "${CONFIG_PATCH}" << EOF
  $(<"${key_file}.pub")
EOF
done

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

$WAS_TRACING && set -x

echo "Replaced install-config sshKey with FIPS-compatible keys (${SSH_KEY_TYPE_LIST})"
echo "sshKey: XXXXXXXXXXXXXXXXXXXXXXX"
