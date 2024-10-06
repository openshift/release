#!/bin/bash

set -e
set -o pipefail

# Fix user IDs in a container
~/fix_uid.sh

BASTION_ADDRESS="$(cat /var/run/bastion1/bastion-address)"
VPN_URL="$(cat /var/run/bastion1/vpn-url)"
VPN_USERNAME="$(cat /var/run/bastion1/vpn-username)"
VPN_PASSWORD="$(cat /var/run/bastion1/vpn-password)"

echo "$VPN_PASSWORD" | openconnect --protocol=anyconnect --user="$VPN_USERNAME" "$VPN_URL" --passwd-on-stdin --background

ping -c 5 $BASTION_ADDRESS
