#!/bin/bash
set -xeuo pipefail

export CLOUDSDK_PYTHON=python3

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"

chmod +x "${SHARED_DIR}/login_script.sh"
${SHARED_DIR}/login_script.sh

# Print the git branch
branch=$(git rev-parse --abbrev-ref HEAD)
echo "Printing the current branch of cri-o: $branch"

ls -al /

# Trying to copy the content from /src
tar -czf - /go | ssh "${SSHOPTS[@]}" ${IP} -- "cat > \${HOME}/cri-o.tar.gz"
echo "Transferring source done"

echo "Running remote setup command"
timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" ${IP} -- bash - <<EOF
    set -xeuo pipefail
    sudo dnf install -y python3.11

    export GOROOT=/usr/local/go
    echo "GOROOT=\"/usr/local/go\"" | sudo tee -a /etc/environment
    mkdir -p \${HOME}/logs/artifacts
    mkdir -p /tmp/artifacts/logs
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3.11 get-pip.py
    python3.11 -m pip install ansible

    # setup the directory where the tests will run
    REPO_DIR="/home/deadbeef/cri-o"
    mkdir -p "\${REPO_DIR}"

    # copy the agent sources on the remote machine
    sudo tar -xzf cri-o.tar.gz -C "\${REPO_DIR}"
    sudo chown -R deadbeef \${REPO_DIR}
    rm -f cri-o.tar.gz
    cd "\${REPO_DIR}/contrib/test/ci"
    echo "localhost" >> hosts
    sudo chown -R deadbeef /tmp/*
    sudo chmod -R 777 /tmp/*
EOF
