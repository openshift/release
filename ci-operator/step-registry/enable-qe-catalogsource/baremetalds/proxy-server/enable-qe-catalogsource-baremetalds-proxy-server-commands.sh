#!/bin/bash

#This script sets up two podman containers as proxy servers, one for Quay.io and another for brew.registry.redhat.io.
#It copies necessary files, configures the containers with authentication and TLS settings, and updates the firewall to allow traffic on ports 6001 and 6002.

set -e

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_creds_encrypted_htpasswd" "root@${IP}:/home/registry_creds_encrypted_htpasswd"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_brew.json" "root@${IP}:/home/registry_brew.json"
scp "${SSHOPTS[@]}" "/var/run/vault/mirror-registry/registry_quay_proxy.json" "root@${IP}:/home/registry_quay_proxy.json"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -eo pipefail

cd /root/dev-scripts
source common.sh
set +x

echo "config quay.io proxy server"
mkdir -p "${WORKING_DIR}"/registry-6001/{data,auth,certs}
cp -r "${WORKING_DIR}"/registry/certs/* "${WORKING_DIR}"/registry-6001/certs
cat "/home/registry_creds_encrypted_htpasswd" > "${WORKING_DIR}"/registry-6001/auth/htpasswd
podman run -d --name poc-registry-6001 --net host --log-opt max-size=10mb \
  -e REGISTRY_HTTP_ADDR=:6001 \
  -v "${WORKING_DIR}"/registry-6001:/var/lib/registry:z \
  -v "${WORKING_DIR}"/registry-6001/auth:/auth \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM='Registry Realm' \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -v "${WORKING_DIR}"/registry-6001/certs:/certs:z \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/"${REGISTRY_CRT}" \
  -e REGISTRY_HTTP_TLS_KEY=/certs/registry.2.key \
  -e REGISTRY_PROXY_REMOTEURL="https://quay.io" \
  -e REGISTRY_PROXY_USERNAME="$(cat /home/registry_quay_proxy.json | jq -r '.user')" \
  -e REGISTRY_PROXY_PASSWORD="$(cat /home/registry_quay_proxy.json | jq -r '.password')" quay.io/openshifttest/registry:2

echo "config brew.registry.redhat.io proxy server"
mkdir -p "${WORKING_DIR}"/registry-6002/{data,auth,certs}
cp -r "${WORKING_DIR}"/registry/certs/* "${WORKING_DIR}"/registry-6002/certs
cat "/home/registry_creds_encrypted_htpasswd" > "${WORKING_DIR}"/registry-6002/auth/htpasswd
podman run -d --name poc-registry-6002 --net host --log-opt max-size=10mb \
  -e REGISTRY_HTTP_ADDR=:6002 \
  -v "${WORKING_DIR}"/registry-6002:/var/lib/registry:z \
  -v "${WORKING_DIR}"/registry-6002/auth:/auth \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM='Registry Realm' \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -v "${WORKING_DIR}"/registry-6002/certs:/certs:z \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/"${REGISTRY_CRT}" \
  -e REGISTRY_HTTP_TLS_KEY=/certs/registry.2.key \
  -e REGISTRY_PROXY_REMOTEURL="https://brew.registry.redhat.io" \
  -e REGISTRY_PROXY_USERNAME="$(cat /home/registry_brew.json | jq '.user')" \
  -e REGISTRY_PROXY_PASSWORD="$(cat /home/registry_brew.json | jq -r '.password')" quay.io/openshifttest/registry:2

echo "update firewall"
sudo firewall-cmd --zone=libvirt --add-port=6001/tcp
sudo firewall-cmd --zone=libvirt --add-port=6002/tcp
EOF

if [ ! -f "${SHARED_DIR}/mirror_registry_url" ] ; then
  oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]' | head -n 1 | cut -d '/' -f 1 > "${SHARED_DIR}/mirror_registry_url"
fi