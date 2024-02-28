#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

export SPRAYPROXY_SERVER_URL \
  SPRAYPROXY_SERVER_TOKEN

SPRAYPROXY_SERVER_URL=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-url)
SPRAYPROXY_SERVER_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-token)

webhook_url=$(cat "${SHARED_DIR}/webhook_url")

register_pac_server(){
  echo "Registering PAC server to SprayProxy server"
  for _ in {1..5}; do
    if curl -k -X POST -H "Authorization: Bearer ${SPRAYPROXY_SERVER_TOKEN}" "${SPRAYPROXY_SERVER_URL}"/backends --data '{"url": "'"$webhook_url"'"}'; then
      break
    fi
    sleep 5
  done
}

list_pac_server(){
  echo "List PAC server from SprayProxy server"
  for _ in {1..5}; do
    if curl -k -X GET -H "Authorization: Bearer ${SPRAYPROXY_SERVER_TOKEN}" "${SPRAYPROXY_SERVER_URL}"/backends; then
      break
    fi
    sleep 5
  done
}

register_pac_server
list_pac_server
