#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

#####################################
#####################################

instance_name=$(<"${SHARED_DIR}/gcp-instance-ids.txt")

tar -czf - . | gcloud compute ssh --zone="${ZONE}" ${instance_name} -- "cat > \${HOME}/cri-o.tar.gz"
timeout --kill-after 10m 400m gcloud compute ssh --zone="${ZONE}" ${instance_name} -- bash - << EOF 
    export GOROOT=/usr/local/go
    echo GOROOT="/usr/local/go" | sudo tee -a /etc/environment
    mkdir -p \${HOME}/logs/artifacts
    mkdir -p /tmp/artifacts/logs

    sudo dnf install python39 -y
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3.9 get-pip.py
    python3.9 -m pip install ansible

    # setup the directory where the tests will the run
    REPO_DIR="/home/deadbeef/cri-o"
    mkdir -p "\${REPO_DIR}"
    # copy the agent sources on the remote machine
    tar -xzvf cri-o.tar.gz -C "\${REPO_DIR}"
    cd "\${REPO_DIR}/contrib/test/ci"
    echo "localhost" >> hosts
    ansible-playbook integration-main.yml -i hosts -e "TEST_AGENT=prow" --connection=local -vvv 
EOF

