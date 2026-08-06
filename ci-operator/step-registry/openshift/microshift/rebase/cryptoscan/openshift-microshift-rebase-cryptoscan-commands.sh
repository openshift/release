#!/bin/bash
set -xeuo pipefail

if [[ "$JOB_NAME" == rehearse* ]]; then
    echo "INFO: \$JOB_NAME starts with rehearse - running in DRY RUN mode"
    export DRY_RUN=y
fi

# Setup rootless podman (mirrors nested-podman entrypoint.sh)
if ! whoami &> /dev/null; then
    if [ -w /etc/passwd ]; then
        echo "${USER_NAME:-user}:x:$(id -u):0:${USER_NAME:-user} user:${HOME}:/bin/bash" >> /etc/passwd
        echo "${USER_NAME:-user}:x:$(id -u):" >> /etc/group
    fi
fi
PODMAN_USER=$(whoami)
PODMAN_START_ID=$(( $(id -u)+1 ))
PODMAN_END_ID=$(( 65536-PODMAN_START_ID ))
echo "${PODMAN_USER}:${PODMAN_START_ID}:${PODMAN_END_ID}" > /etc/subuid
echo "${PODMAN_USER}:${PODMAN_START_ID}:${PODMAN_END_ID}" > /etc/subgid

mkdir -p "${HOME}/.config/containers"
cat > "${HOME}/.config/containers/registries.conf" <<PODMAN_EOF
unqualified-search-registries = [
  "registry.access.redhat.com",
  "registry.redhat.io",
  "docker.io"
]
short-name-mode = "permissive"
PODMAN_EOF
cat > "${HOME}/.config/containers/storage.conf" <<PODMAN_EOF
[storage]
driver = "vfs"
PODMAN_EOF

export PATH="${HOME}/.local/bin:${PATH}"
python3 -m ensurepip --upgrade
pip3 install setuptools-rust cryptography pyyaml pygithub gitpython

cp /secrets/import-secret/.dockerconfigjson ${HOME}/.pull-secret.json

cd /go/src/github.com/openshift/microshift/
DEST_DIR=${HOME}/.local/bin ./scripts/fetch_tools.sh yq
./scripts/auto-rebase/rebase_job_entrypoint.sh
