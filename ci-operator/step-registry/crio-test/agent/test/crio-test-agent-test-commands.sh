#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

echo "entering setup and perform the test"
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/crio-test.tar.gz"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF 
    export HOME=/root
    export GOROOT=/usr/local/go
    echo GOROOT="/usr/local/go" >> /etc/environment
    cat /etc/environment 

    dnf install python39 -y
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3.9 get-pip.py
    python3.9 -m pip install ansible

    # setup the directory where the tests will the run
    REPO_DIR="/home/crio-test"
    mkdir -p "\${REPO_DIR}"
    # NVMe makes it faster
    NVME_DEVICE="/dev/nvme0n1"
    if [ -e "\$NVME_DEVICE" ];
    then
        mkfs.xfs -f "\${NVME_DEVICE}"
        mount "\${NVME_DEVICE}" "\${REPO_DIR}"
    fi
    # copy the agent sources on the remote machine
    tar -xzvf crio-test.tar.gz -C "\${REPO_DIR}"
    chown -R root:root "\${REPO_DIR}"
    cd "\${REPO_DIR}/contrib/test/integration"
    echo "localhost" >> hosts
EOF
