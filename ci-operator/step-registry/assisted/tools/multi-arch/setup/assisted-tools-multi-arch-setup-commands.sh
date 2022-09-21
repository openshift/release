#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted tools setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted.tar.gz"

echo "### Setting up tests"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash -x - << EOF
    # install and start docker
    dnf install -y 'dnf-command(config-manager)'
    dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io

    # attempt at addressing quay.io flakyness
    # store container logs into journald
    mkdir -p /etc/docker
    echo '{"debug": true, "max-concurrent-downloads": 1, "max-download-attempts": 50, "log-driver": "journald"}' | tee /etc/docker/daemon.json
    systemctl enable --now docker

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

    # copy the tools sources on the remote machine
    tar -xzvf assisted.tar.gz -C "\${REPO_DIR}"
    chown -R root:root "\${REPO_DIR}"

    docker buildx create --name mybuilder --platform linux/amd64,linux/arm64
    docker buildx inspect mybuilder --bootstrap
    docker buildx use mybuilder
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
EOF

REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"

echo "************ Copying secret file ${REGISTRY_TOKEN_FILE} *****************************"
cat ${REGISTRY_TOKEN_FILE} | ssh "${SSHOPTS[@]}" "root@${IP}" "mkdir -p /root/.docker; cat > /root/.docker/config.json"

