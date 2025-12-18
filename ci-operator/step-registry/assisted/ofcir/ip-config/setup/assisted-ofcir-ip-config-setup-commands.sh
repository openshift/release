#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

echo "************ assisted-ofcir-ip-config-setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/lifecycle-agent.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), \$0 }') 2>&1

set -xeo pipefail

REPO_DIR="/home/lifecycle-agent"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar lifecycle-agent code..."
  tar -xzvf /root/lifecycle-agent.tar.gz -C "\${REPO_DIR}"
fi

EOF