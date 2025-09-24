#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted agent setup command ************"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common/lib/host-contract/host-contract.sh"

host_contract::load

HOST_TARGET="${HOST_SSH_USER}@${HOST_SSH_HOST}"
SSH_ARGS=("${HOST_SSH_OPTIONS[@]}")

tar -czf - . | ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" "cat > /root/assisted.tar.gz"

# copy pull-secret
ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" "mkdir -p /root/.docker"
cat "${CLUSTER_PROFILE_DIR}/pull-secret" | ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" "cat > /root/.docker/config.json"

echo "### Setting up tests"
timeout --kill-after 10m 120m ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" bash - << EOF
    # install and start docker
    dnf install -y 'dnf-command(config-manager)'
    dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io

    # attempt at addressing quay.io flakyness
    # store container logs into journald
    mkdir -p /etc/docker
    echo '{"debug": true, "max-concurrent-downloads": 1, "max-download-attempts": 50, "log-driver": "journald"}' | tee /etc/docker/daemon.json
    systemctl enable --now docker

    # install skipper
    dnf install -y python3-pip
    pip3 install --upgrade pip
    pip3 install strato-skipper==2.0.2

    # misc tools
    dnf install -y sos

    # setup the directory where the tests will the run
    REPO_DIR="/home/assisted"
    mkdir -p "\${REPO_DIR}"

    # NVMe makes it faster
    NVME_DEVICE="/dev/nvme0n1"
    if [ -e "\$NVME_DEVICE" ];
    then
        mkfs.xfs -f "\${NVME_DEVICE}"
        mount "\${NVME_DEVICE}" "\${REPO_DIR}"
    fi

    # copy the agent sources on the remote machine
    tar -xzvf assisted.tar.gz -C "\${REPO_DIR}"
    chown -R root:root "\${REPO_DIR}"
EOF
