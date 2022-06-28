#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

echo "beginning e2e test"
# # shellcheck source=/dev/null
# source "${SHARED_DIR}/packet-conf.sh"

# tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/crio-test.tar.gz"
# timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF 
#     ansible-playbook critest-main.yml -i hosts -e "host=localhost" -e "GOPATH=/usr/local/go" --connection=local -vvv 
# EOF
