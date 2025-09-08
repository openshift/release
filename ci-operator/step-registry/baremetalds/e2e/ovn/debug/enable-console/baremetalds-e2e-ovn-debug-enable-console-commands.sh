#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

if [ "${ENABLE_DEBUG_CONSOLE:-}" != "true" ]; then
  echo "ENABLE_DEBUG_CONSOLE is not set, exiting..."
  exit 0
fi

PACKET_CONF="${SHARED_DIR}/packet-conf.sh"
if [ ! -f "${PACKET_CONF}" ]; then
    echo "Error: packet-conf.sh not found at $PACKET_CONF"
    exit 1
fi

# Fetch packet basic configuration
# shellcheck disable=SC1090
source "${PACKET_CONF}"

set +x
PASSWD=$(</dev/random tr -cd '[:alnum:]' | fold -w 10 | head -1 || true)
echo "PASSWD=$PASSWD" > "${SHARED_DIR}"/console.passwd
set -x

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF
source ~/dev-scripts-additional-config
nodes=\$(oc get node -o jsonpath='{.items[*].metadata.name}')

for node in \$nodes; do
  oc debug node/"\$node" -- chroot /host bash -c "rpm-ostree kargs --append-if-missing=console=ttyS0,115200n8"
done

oc adm reboot-machine-config-pool mcp/worker mcp/master
oc adm wait-for-node-reboot nodes --all

for node in \$nodes; do
  oc debug node/"\$node" -- chroot /host bash -c "echo $PASSWD | passwd core --stdin"
  # preload toolbox image to have it available on disconnected nodes
  oc debug node/"\$node" -- chroot /host toolbox exit
done
EOF
