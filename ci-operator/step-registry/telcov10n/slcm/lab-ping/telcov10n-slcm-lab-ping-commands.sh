#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Fix user IDs in a container
~/fix_uid.sh

# Read a scalar out of a mounted YAML secret. yq is used rather than grep+sed
# because stripping quotes with sed also drops apostrophes that belong to the
# value itself (a password like 'pa''ss' would arrive as pass).
read_yaml_key() {
  local path="$1" key="$2" value

  if ! yq eval 'true' "${path}" >/dev/null 2>&1; then
    echo "Error: ${path} is not valid YAML" >&2
    return 1
  fi

  value="$(KEY="${key}" yq eval '.[env(KEY)]' "${path}")"
  if [[ "${value}" == "null" ]]; then
    echo "Error: ${key} not found in ${path}" >&2
    return 1
  fi

  printf '%s' "${value}"
}

# Extract the bastion/VPN credentials with tracing off so they never hit the build log.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
BASTION_ADDRESS="$(read_yaml_key /var/run/bastion1/secret bastion-address)" || exit 1
VPN_URL="$(read_yaml_key /var/run/bastion1/secret vpn-url)" || exit 1
VPN_USERNAME="$(read_yaml_key /var/run/bastion1/secret vpn-username)" || exit 1
# For password with special characters
VPN_PASSWORD="$(read_yaml_key /var/run/bastion1/secret vpn-password)" || exit 1
SSH_KEY_PATH=/var/run/ssh-key/ssh-key
SSH_KEY=~/key
JUMP_SERVER_ADDRESS="$(read_yaml_key /var/run/bastion1/secret jump-server)" || exit 1
IFNAME=tun10

# Write the VPN/bastion values to a local file instead of passing them as ssh
# argv, which would otherwise show up verbatim in the traced command line and
# in `ps`/`/proc` on this host for the life of the process.
VPN_ENV_FILE=~/vpn_env
install -m 600 /dev/null "${VPN_ENV_FILE}"
{
  printf 'VPN_URL=%q\n' "${VPN_URL}"
  printf 'VPN_USERNAME=%q\n' "${VPN_USERNAME}"
  printf 'VPN_PASSWORD=%q\n' "${VPN_PASSWORD}"
  printf 'IFNAME=%q\n' "${IFNAME}"
  printf 'BASTION_ADDRESS=%q\n' "${BASTION_ADDRESS}"
} > "${VPN_ENV_FILE}"
$WAS_TRACING && set -x

cp $SSH_KEY_PATH $SSH_KEY
chmod 600 $SSH_KEY

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${SSH_KEY}")

# Copy the credentials file over the existing SSH channel — scp's argv is just
# paths, so it stays safe to trace — instead of passing values on the command line.
REMOTE_VPN_ENV_FILE="/tmp/vpn_env_${BUILD_ID}"
scp "${SSHOPTS[@]}" "${VPN_ENV_FILE}" "telcov10n@${JUMP_SERVER_ADDRESS}:${REMOTE_VPN_ENV_FILE}"
rm -f "${VPN_ENV_FILE}"

# Run commands from the bastion
timeout -s 9 10m ssh "${SSHOPTS[@]}" "telcov10n@${JUMP_SERVER_ADDRESS}" bash -s -- \
  "${REMOTE_VPN_ENV_FILE}" << 'EOF'
    set -o nounset
    set -o errexit
    set -o pipefail

    VPN_ENV_FILE="${1}"
    # shellcheck disable=SC1090
    source "${VPN_ENV_FILE}"
    rm -f "${VPN_ENV_FILE}"

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
    printf '%s\n' "${VPN_PASSWORD}" | sudo openconnect -b --interface=${IFNAME} --script="/tmp/vpnc-script-custom" --useragent="AnyConnect-compatible OpenConnect VPN Agent" --user=${VPN_USERNAME} --server=${VPN_URL} --gnutls-priority="NORMAL:-VERS-ALL:+VERS-TLS1.2:+RSA:+AES-128-CBC:+SHA1"
    sleep 10
    ping -c 5 $BASTION_ADDRESS

    # Disconnect
    PIDS=$(pgrep openconnect) && [ -n "$PIDS" ] && sudo kill -9 $PIDS || true
EOF
