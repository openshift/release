#!/bin/bash

set -ex

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_creds_encrypted_htpasswd" "root@${IP}:/home/registry_creds_encrypted_htpasswd"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_brew.json" "root@${IP}:/home/registry_brew.json"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_quay_proxy.json" "root@${IP}:/home/registry_quay_proxy.json"

