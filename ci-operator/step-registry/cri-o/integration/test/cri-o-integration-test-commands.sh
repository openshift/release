#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
echo "${IP}" 
echo "${SSHOPTS[@]}"
 
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/cri-o.tar.gz"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF 
    export HOME=/root
    mkdir /tmp/artifacts
    mkdir /logs
    mkdir /logs/artifacts 
    mkdir /tmp/artifacts/logs

    dnf install python39 -y
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3.9 get-pip.py
    python3.9 -m pip install ansible

    # setup the directory where the tests will the run
    REPO_DIR="/root/cri-o"
    mkdir -p "\${REPO_DIR}"
    # NVMe makes it faster
    NVME_DEVICE="/dev/nvme0n1"
    if [ -e "\$NVME_DEVICE" ];
    then
        mkfs.xfs -f "\${NVME_DEVICE}"
        mount "\${NVME_DEVICE}" "\${REPO_DIR}"
    fi
    # copy the agent sources on the remote machine
    tar -xzvf cri-o.tar.gz -C "\${REPO_DIR}"
    chown -R root:root "\${REPO_DIR}"
    cd "\${REPO_DIR}/contrib/test/ci"
    echo "localhost" >> hosts
    ansible-playbook integration-main.yml -i hosts -e "TEST_AGENT=prow" --connection=local -vvv 
EOF

