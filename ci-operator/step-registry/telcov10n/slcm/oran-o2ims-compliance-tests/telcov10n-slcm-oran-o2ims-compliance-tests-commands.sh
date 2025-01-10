#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Fix user IDs in a container
~/fix_uid.sh

BASTION_ADDRESS="$(cat /var/run/bastion1/bastion-address)"
VPN_URL="$(cat /var/run/bastion1/vpn-url)"
VPN_USERNAME="$(cat /var/run/bastion1/vpn-username)"
# For password with special characters
VPN_PASSWORD=`cat /var/run/bastion1/vpn-password`
SSH_KEY_PATH=/var/run/ssh-key/ssh-key
SSH_KEY=~/key
JUMP_SERVER_ADDRESS="$(cat /var/run/bastion1/jump-server)"
IFNAME=tun20
REMOTE_ARTIFACTS_DIR=/home/kni/test_results/

cp $SSH_KEY_PATH $SSH_KEY
chmod 600 $SSH_KEY

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${SSH_KEY}")

# Run commands from the bastion
timeout -s 9 10m ssh "${SSHOPTS[@]}" "kni@${JUMP_SERVER_ADDRESS}" bash -s -- \
  "'${VPN_URL}'" "'${VPN_USERNAME}'" "'${VPN_PASSWORD}'" "'${IFNAME}'" "'${BASTION_ADDRESS}'" "'${REMOTE_ARTIFACTS_DIR}'"  << 'EOF'
    set -o nounset
    set -o errexit
    set -o pipefail

    VPN_URL="${1}"
    VPN_USERNAME="${2}"
    VPN_PASSWORD="${3}"
    IFNAME="${4}"
    BASTION_ADDRESS="${5}"
    ARTIFACTS_DIR=${6}
    mkdir $ARTIFACTS_DIR

    PIDS=$(pgrep openconnect) && [ -n ${PIDS} ] && sudo kill -9 $PIDS || true

    ### Create custom script to keep DNS servers
    cat <<END_CAT > /tmp/vpnc-script-custom
    #!/bin/bash
    # this is located in: /etc/vpnc/vpnc-script-custom
    # Use internal lab DNS server
    export INTERNAL_IP4_DNS=("10.47.242.10" "10.38.5.26")
    # Run vpnc-script
    exec /etc/vpnc/vpnc-script "$@"
END_CAT



    sudo adduser ${VPN_USERNAME} || true
    sudo chmod 333 /tmp/vpnc-script-custom

    sudo -E ip link del ${IFNAME} || true
    sudo -E ip tuntap add ${IFNAME} mode tun user ${VPN_USERNAME}
    sudo chmod 666 /dev/net/tun
    echo $VPN_PASSWORD | sudo openconnect -b --interface=${IFNAME} --script="/tmp/vpnc-script-custom" --useragent="AnyConnect-compatible OpenConnect VPN Agent" --user=${VPN_USERNAME} --server=${VPN_URL} --gnutls-priority="NORMAL:-VERS-ALL:+VERS-TLS1.2:+RSA:+AES-128-CBC:+SHA1"
    sleep 10

    cd eco-ci-cd
    git fetch --all
    git checkout main

    cat << END_INVENTORY > robot_inventory.yml
---
robots:
  hosts:
    robot:
      ansible_host: "${BASTION_ADDRESS}"
      artifacts_dir: "${ARTIFACTS_DIR}"
END_INVENTORY

    ansible-playbook -i robot_inventory.yml playbooks/run_compliance_tests.yml

    # Disconnect
    PIDS=$(pgrep openconnect) && [ -n "$PIDS" ] && sudo kill -9 $PIDS || true
EOF

rsync -a -e "ssh ${SSHOPTS[*]}" "kni@${JUMP_SERVER_ADDRESS}:${REMOTE_ARTIFACTS_DIR}" "${ARTIFACTS_DIR}/compliance_test_results"
