#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


source "${SHARED_DIR}/packet-conf.sh" && scp "${SSHOPTS[@]}" "${SHARED_DIR}/nested_kubeconfig" "root@${IP}:nested_kubeconfig"

# Collect all hosted cluster service NodePorts to add to squid's allowed_ssl_ports.
# These files are written by the hypershift-mce-agent-create-hostedcluster step.
EXTRA_PORTS=""
for portfile in "${SHARED_DIR}"/hosted_*_port; do
  if [ -f "$portfile" ]; then
    port=$(cat "$portfile")
    if [ -n "$port" ]; then
      EXTRA_PORTS="${EXTRA_PORTS} ${port}"
    fi
  fi
done
echo "Extra hosted cluster service ports for squid: ${EXTRA_PORTS}"

NUTANIX_PROXY=false
if [[ -f "${SHARED_DIR}/nutanix_context.sh" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  routes_json=$(oc get routes -A -o json)
  hosts=$(jq -r '.items[] | select(.metadata.namespace == "multicluster-engine" or .metadata.namespace == "openshift-multicluster-engine") | select((((.metadata.name // "") + " " + (.spec.to.name // "")) | test("assisted.*(service|image)|service.*assisted"; "i"))) | .spec.host // empty' <<<"${routes_json}" | sort -u)
  if [[ -z "${hosts}" ]]; then
    echo "No Assisted Service route was discovered; refusing to broaden the Squid ACL."
    exit 1
  fi

  printf '%s\n' "${hosts}" > "${SHARED_DIR}/nutanix_squid_allowed_hosts"
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/nutanix_squid_allowed_hosts" "root@${IP}:/tmp/nutanix_squid_allowed_hosts"
  NUTANIX_PROXY=true
fi

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${NUTANIX_PROXY}" ${EXTRA_PORTS} << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -x

# Collect extra ports passed as arguments
NUTANIX_PROXY=$1
shift
EXTRA_PORTS=("$@")

API_URL=$(yq -r ".clusters[0].cluster.server" nested_kubeconfig)
API_SERVER=$(echo "$API_URL" | sed 's|^http[s]*://||' | sed 's|:[0-9]*$||')
API_PORT=$(echo "$API_URL" | sed 's|^http[s]*://||' | grep -o ':[0-9]*$' | tr -d ':')

if [[ ! $API_SERVER =~ \[ && ! $API_SERVER =~ \] && ! $API_SERVER =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    API_SERVER=".${API_SERVER}"
fi
sed -i "1 s|$| $API_SERVER|" $HOME/squid.conf

# Add the API server port to allowed_ssl_ports if it is not already listed
if [[ -n "$API_PORT" ]] && ! grep -q "acl allowed_ssl_ports port.*\b${API_PORT}\b" $HOME/squid.conf; then
    sed -i "s|^acl allowed_ssl_ports port.*|& $API_PORT|" $HOME/squid.conf
fi

# Add all hosted cluster service ports (oauth-openshift, konnectivity-server,
# ignition-server-proxy, etc.) to allowed_ssl_ports
for port in "${EXTRA_PORTS[@]}"; do
  if [[ -n "$port" ]] && ! grep -q "acl allowed_ssl_ports port.*\b${port}\b" $HOME/squid.conf; then
    sed -i "s|^acl allowed_ssl_ports port.*|& $port|" $HOME/squid.conf
  fi
done

if [[ "${NUTANIX_PROXY}" == "true" ]]; then
  if [[ ! -s /tmp/nutanix_squid_allowed_hosts ]]; then
    echo "The Nutanix Squid destination list is missing."
    exit 1
  fi
  while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    if [[ ! "${host}" =~ ^[A-Za-z0-9.-]+$ ]]; then
      echo "Refusing invalid Squid destination ${host}"
      exit 1
    fi
    if ! grep -Fq " ${host}" "$HOME/squid.conf"; then
      sed -i "1 s|$| ${host}|" "$HOME/squid.conf" || exit 1
    fi
  done < /tmp/nutanix_squid_allowed_hosts
  rm -f /tmp/nutanix_squid_allowed_hosts
fi
cat $HOME/squid.conf

sudo setenforce 0
sudo podman stop -t 120 external-squid
sudo podman run -d --rm \
     --net host \
     --volume $HOME/squid.conf:/etc/squid/squid.conf \
     --name external-squid \
     --dns 127.0.0.1 \
     quay.io/openshifttest/squid-proxy:multiarch
EOF

CIRFILE=$SHARED_DIR/cir
PROXYPORT=8213
if [ -f $CIRFILE ] ; then
    PROXYPORT=$(jq -r ".extra | select( . != \"\") // {}" < $CIRFILE | jq ".ofcir_port_proxy // 8213" -r)
fi

echo "Adding proxy-url in kubeconfig"
sed -i "/- cluster/ a\    proxy-url: http://$IP:${PROXYPORT}/" "${SHARED_DIR}"/nested_kubeconfig
