#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


source "${SHARED_DIR}/packet-conf.sh" && scp "${SSHOPTS[@]}" "${SHARED_DIR}/nested_kubeconfig" "root@${IP}:nested_kubeconfig"

# Collect all hosted cluster service NodePorts to add to squid's allowed_ssl_ports.
# These files are written by the hypershift-mce-agent-create-hostedcluster step.
EXTRA_PORTS=()
for portfile in "${SHARED_DIR}"/hosted_*_port; do
  if [ -f "$portfile" ]; then
    port=$(cat "$portfile")
    if [ -n "$port" ]; then
      EXTRA_PORTS+=("$port")
    fi
  fi
done
echo "Extra hosted cluster service ports for squid: ${EXTRA_PORTS[*]}"

NUTANIX_PROXY=false
run_id=""
if [[ -f "${SHARED_DIR}/nutanix_context.sh" ]]; then
  identity_file="${SHARED_DIR}/nutanix_ingress_tunnel_identity.json"
  if [[ ! -s "$identity_file" ]] || ! jq -e \
      --arg lease "${NUTANIX_QUOTA_SLICE:-}" --arg job "${PROW_JOB_ID:-}" \
      '.schemaVersion == 1 and .lease == $lease and .prowJobID == $job' \
      "$identity_file" >/dev/null; then
    echo "The Nutanix Squid identity does not match this run."
    exit 1
  fi
  run_id=$(jq -er '.gatewayName | sub("^hcp-nxwg-"; "")' "$identity_file")
  if [[ ! "$run_id" =~ ^[0-9a-f]{8}-[0-9a-f]{8}$ ]]; then
    echo "The Nutanix Squid identity has an invalid run ID."
    exit 1
  fi
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  routes_json=$(oc get routes -A -o json)
  hosts=$(jq -r '.items[] | select(.metadata.namespace == "multicluster-engine" or .metadata.namespace == "openshift-multicluster-engine") | select((((.metadata.name // "") + " " + (.spec.to.name // "")) | test("assisted.*(service|image)|service.*assisted"; "i"))) | .spec.host // empty' <<<"${routes_json}" | sort -u)
  if [[ -z "${hosts}" ]]; then
    echo "No Assisted Service route was discovered; refusing to broaden the Squid ACL."
    exit 1
  fi
  hosts=$(printf '%s\n' "${hosts}" registry.redhat.io brew.registry.redhat.io .quay.io quay-proxy.ci.openshift.org | sort -u)

  printf '%s\n' "${hosts}" > "${SHARED_DIR}/nutanix_squid_allowed_hosts"
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/nutanix_squid_allowed_hosts" "root@${IP}:/tmp/nutanix_squid_allowed_hosts_${run_id}"
  NUTANIX_PROXY=true
fi

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${NUTANIX_PROXY}" "$run_id" "${EXTRA_PORTS[@]}" << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -euo pipefail

# Collect extra ports passed as arguments
NUTANIX_PROXY=$1
run_id=$2
shift 2
EXTRA_PORTS=("$@")

API_URL=$(yq -r ".clusters[0].cluster.server" nested_kubeconfig)
API_SERVER=$(echo "$API_URL" | sed 's|^http[s]*://||' | sed 's|:[0-9]*$||')
API_PORT=$(echo "$API_URL" | sed 's|^http[s]*://||' | grep -o ':[0-9]*$' | tr -d ':' || true)

if [[ ! $API_SERVER =~ \[ && ! $API_SERVER =~ \] && ! $API_SERVER =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    API_SERVER=".${API_SERVER}"
fi
if [[ "${NUTANIX_PROXY}" == "true" ]]; then
  hosts_file="/tmp/nutanix_squid_allowed_hosts_${run_id}"
  squid_config="$HOME/squid.conf"
  if [[ ! -s "$hosts_file" ]]; then
    echo "The Nutanix Squid destination list is missing."
    exit 1
  fi
  if [[ ! "$API_SERVER" =~ ^[A-Za-z0-9.-]+$ ]] ||
      grep -Eq '^# (BEGIN|END) hypershift-nutanix-squid ' "$squid_config"; then
    echo "The Squid config has an invalid API host or an existing Nutanix ACL block."
    exit 1
  fi
  if [[ $(grep -c '^acl cluster dstdomain ' "$squid_config") -ne 1 ||
        $(grep -c '^http_access allow CONNECT cluster$' "$squid_config") -ne 1 ]]; then
    echo "The Squid config does not have the expected ACL insertion points."
    exit 1
  fi

  work_dir=$(mktemp -d "$HOME/.squid-nutanix.XXXXXX")
  trap 'rm -rf "$work_dir"; rm -f "$hosts_file"' EXIT
  acl_block="$work_dir/acl"
  access_block="$work_dir/access"
  candidate="$work_dir/config"
  s3_acl="nutanix_s3_${run_id//-/_}"
  {
    printf '# BEGIN hypershift-nutanix-squid %s ACL\n' "$run_id"
    printf 'acl cluster dstdomain %s' "$API_SERVER"
  } > "$acl_block"
  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    if [[ ! "${host}" =~ ^[A-Za-z0-9.-]+$ ]]; then
      echo "Refusing an invalid Squid destination."
      exit 1
    fi
    printf ' %s' "$host" >> "$acl_block"
  done < "$hosts_file"
  printf '\n' >> "$acl_block"
  ports=()
  [[ -z "$API_PORT" ]] || ports+=("$API_PORT")
  ports+=("${EXTRA_PORTS[@]}")
  if (( ${#ports[@]} > 0 )); then
    printf 'acl allowed_ssl_ports port' >> "$acl_block"
    for port in "${ports[@]}"; do
      if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        echo "Refusing an invalid Squid port."
        exit 1
      fi
      printf ' %s' "$port" >> "$acl_block"
    done
    printf '\n' >> "$acl_block"
  fi
  printf 'acl %s dstdom_regex -i (^|\\.)s3([.-][a-z0-9-]+)*\\.amazonaws\\.com$\n' "$s3_acl" >> "$acl_block"
  printf '# END hypershift-nutanix-squid %s ACL\n' "$run_id" >> "$acl_block"
  printf '# BEGIN hypershift-nutanix-squid %s ACCESS\nhttp_access allow CONNECT %s\n# END hypershift-nutanix-squid %s ACCESS\n' \
    "$run_id" "$s3_acl" "$run_id" > "$access_block"

  awk -v acl_file="$acl_block" -v access_file="$access_block" '
    function insert(file, line) {
      while ((getline line < file) > 0) print line
      close(file)
    }
    /^acl cluster dstdomain / { print; insert(acl_file); next }
    /^http_access allow CONNECT cluster$/ { print; insert(access_file); next }
    { print }
  ' "$squid_config" > "$candidate"
  chmod --reference="$squid_config" "$candidate"
  mv "$candidate" "$squid_config"
else
  sed -i "1 s|$| $API_SERVER|" "$HOME/squid.conf"

  # Add the API server port to allowed_ssl_ports if it is not already listed.
  if [[ -n "$API_PORT" ]] && ! grep -q "acl allowed_ssl_ports port.*\b${API_PORT}\b" "$HOME/squid.conf"; then
    sed -i "s|^acl allowed_ssl_ports port.*|& $API_PORT|" "$HOME/squid.conf"
  fi

  # Add all hosted cluster service ports to allowed_ssl_ports.
  for port in "${EXTRA_PORTS[@]}"; do
    if [[ -n "$port" ]] && ! grep -q "acl allowed_ssl_ports port.*\b${port}\b" "$HOME/squid.conf"; then
      sed -i "s|^acl allowed_ssl_ports port.*|& $port|" "$HOME/squid.conf"
    fi
  done
fi

sudo setenforce 0 || true
if sudo podman container exists external-squid; then
  sudo podman stop -t 120 external-squid
fi
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
