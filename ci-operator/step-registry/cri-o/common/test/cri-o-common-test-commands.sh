#!/bin/bash
set -xeuo pipefail

export CLOUDSDK_PYTHON=python3

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"

chmod +x "${SHARED_DIR}/login_script.sh"
${SHARED_DIR}/login_script.sh

cd /workdir
# Print the git branch
branch=$(git rev-parse --abbrev-ref HEAD)
echo "Printing the current branch of cri-o: $branch"

# Trying to copy the content from /src
tar -czf - . | ssh "${SSHOPTS[@]}" ${IP} -- "cat > \${HOME}/cri-o.tar.gz"
echo "Transferring source done"

echo "Running remote setup command"
timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" ${IP} -- bash - <<EOF
    sudo dnf install -y python3.11

    export GOROOT=/usr/local/go
    echo "GOROOT=\"/usr/local/go\"" | sudo tee -a /etc/environment
    mkdir -p \${HOME}/logs/artifacts
    mkdir -p /tmp/artifacts/logs
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3.11 get-pip.py
    python3.11 -m pip install ansible

    # setup the directory where the tests will run
    SOURCE_DIR="/usr/go/src/github.com/cri-o/cri-o"

    sudo mkdir -p "\${SOURCE_DIR}"

    # copy the agent sources on the remote machine
    sudo tar -xzf cri-o.tar.gz -C "\${SOURCE_DIR}"
    sudo chown -R deadbeef \${SOURCE_DIR}
    rm -f cri-o.tar.gz
    cd "\${SOURCE_DIR}/contrib/test/ci"
    echo "localhost" >> hosts
    sudo chown -R deadbeef /tmp/*
    sudo chmod -R 777 /tmp/*
EOF
