#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

export SPRAYPROXY_SERVER_URL \
  SPRAYPROXY_SERVER_TOKEN

SPRAYPROXY_SERVER_URL=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-url)
SPRAYPROXY_SERVER_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-token)

webhook_url=$(cat "${SHARED_DIR}/webhook_url")

unregister_pac_server(){
  echo "Unregistering PAC server [$webhook_url] from SprayProxy server"
  for _ in {1..5}; do
    if curl -k -X DELETE -H "Authorization: Bearer ${SPRAYPROXY_SERVER_TOKEN}" "${SPRAYPROXY_SERVER_URL}"/backends/"$webhook_url" --data '{"url": "'"$webhook_url"'"}'; then
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

unregister_pac_server
list_pac_server