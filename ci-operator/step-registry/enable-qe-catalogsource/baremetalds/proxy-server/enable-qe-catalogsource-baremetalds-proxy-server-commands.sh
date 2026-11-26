#!/bin/bash

#This script sets up two podman containers as proxy servers, one for Quay.io and another for brew.registry.redhat.io.
#It copies necessary files, configures the containers with authentication and TLS settings, and updates the firewall to allow traffic on ports 6001 and 6002.

set -e

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_creds_encrypted_htpasswd" "root@${IP}:/home/registry_creds_encrypted_htpasswd"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_brew.json" "root@${IP}:/home/registry_brew.json"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_quay_proxy.json" "root@${IP}:/home/registry_quay_proxy.json"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_stage.json" "root@${IP}:/home/registry_stage.json"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -eo pipefail

cd /root/dev-scripts
source common.sh
set +x

setup_proxy_registry() {
  local port=$1
  local name=$2
  local remote_url=$3
  local username=$4
  local password=$5

  echo "config ${name} proxy server"
  mkdir -p "${WORKING_DIR}"/registry-${port}/{data,auth,certs}
  cp -r "${WORKING_DIR}"/registry/certs/* "${WORKING_DIR}"/registry-${port}/certs
  cat "/home/registry_creds_encrypted_htpasswd" > "${WORKING_DIR}"/registry-${port}/auth/htpasswd
  podman run -d --name poc-registry-${port} --net host --log-opt max-size=10mb \
    -e REGISTRY_HTTP_ADDR=:${port} \
    -v "${WORKING_DIR}"/registry-${port}:/var/lib/registry:z \
    -v "${WORKING_DIR}"/registry-${port}/auth:/auth \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -e REGISTRY_AUTH=htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_REALM='Registry Realm' \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    -v "${WORKING_DIR}"/registry-${port}/certs:/certs:z \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/"${REGISTRY_CRT}" \
    -e REGISTRY_HTTP_TLS_KEY=/certs/registry.2.key \
    -e REGISTRY_PROXY_REMOTEURL="${remote_url}" \
    -e REGISTRY_PROXY_USERNAME="${username}" \
    -e REGISTRY_PROXY_PASSWORD="${password}" quay.io/openshifttest/registry:2

  echo "update firewall"
  sudo firewall-cmd --zone=libvirt --add-port=${port}/tcp
}

setup_proxy_registry 6001 "quay.io" "https://quay.io" \
  "$(jq -r '.user' /home/registry_quay_proxy.json)" \
  "$(jq -r '.password' /home/registry_quay_proxy.json)"

setup_proxy_registry 6002 "brew.registry.redhat.io" "https://brew.registry.redhat.io" \
  "$(jq -r '.user' /home/registry_brew.json)" \
  "$(jq -r '.password' /home/registry_brew.json)"

setup_proxy_registry 6003 "registry.stage.redhat.io" "https://registry.stage.redhat.io" \
  "$(jq -r '.user' /home/registry_stage.json)" \
  "$(jq -r '.password' /home/registry_stage.json)"
EOF

if [ ! -f "${SHARED_DIR}/mirror_registry_url" ] ; then
  oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]' | head -n 1 | cut -d '/' -f 1 > "${SHARED_DIR}/mirror_registry_url"
fi
