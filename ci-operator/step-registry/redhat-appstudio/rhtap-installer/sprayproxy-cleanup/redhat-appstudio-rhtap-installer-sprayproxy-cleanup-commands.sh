#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

export SPRAYPROXY_SERVER_URL \
  SPRAYPROXY_SERVER_TOKEN

SPRAYPROXY_SERVER_URL=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-url)
SPRAYPROXY_SERVER_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-token)

unregister_pac_server(){
  webhook_url="$1"
  echo "Unregistering PAC server [$webhook_url] from SprayProxy server"
  for _ in {1..5}; do
    if curl -k -X DELETE -H "Authorization: Bearer ${SPRAYPROXY_SERVER_TOKEN}" "${SPRAYPROXY_SERVER_URL}"/backends --data '{"url": "'"$webhook_url"'"}'; then
      break
    fi
    sleep 5
  done
}
pac_servers=""
get_pac_servers(){
  echo "Get PAC servers registered in SprayProxy server"
  for _ in {1..5}; do
    if pac_servers=$(curl -k -X GET -H "Authorization: Bearer ${SPRAYPROXY_SERVER_TOKEN}" "${SPRAYPROXY_SERVER_URL}"/backends); then
      break
    fi
    sleep 5
  done
}


get_pac_servers
if [[ "$pac_servers" == "Backend urls: " ]]; then
  echo "No PAC servers registered in SprayProxy server"
  exit 0
fi

urls=$(echo "$pac_servers" | grep -o 'https://[^,]*' | sed 's/,//g')
for url in $urls
do
  # validate if the url is a valid PAC server
  host_name=$(echo "$url" | sed 's/https:\/\///')
  if nc -w 5 -z "$host_name" 443 2>/dev/null; then
    continue
  fi
  echo "PAC server $url is not reachable, Delete Pac host $url from SprayProxy server"
  unregister_pac_server "$url"
done