#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

echo "entering setup!!!!"
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/crio-test.tar.gz"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF 
    export HOME=/root
    export GOROOT=/usr/local/go
    echo GOROOT="/usr/local/go" >> /etc/environment
    cat /etc/environment 

    tar -xzvf crio-test.tar.gz -C "\${REPO_DIR}"
    chown -R root:root "\${REPO_DIR}"
    cd "\${REPO_DIR}/contrib/test/integration"
    echo "localhost" >> hosts
    ansible-playbook e2e-main.yml -i hosts -e "host=localhost" -e "GOPATH=/usr/local/go" --connection=local -vvv 
EOF
