#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")

# shellcheck disable=SC1090
. <(yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")' < "${SHARED_DIR}"/external_vips.yaml)
# shellcheck disable=SC2154
if [ ${#api_vip} -eq 0 ] || [ ${#ingress_vip} -eq 0 ]; then
  echo "Unable to parse VIPs"
  exit 1
fi
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
DNS_FORWARD=";DO NOT EDIT; BEGIN $CLUSTER_NAME"

if [ "${ipv4_enabled:-}" == "true" ]; then
  DNS_FORWARD="${DNS_FORWARD}
api.${CLUSTER_NAME} IN A ${api_vip}
provisioner.${CLUSTER_NAME} IN A ${INTERNAL_NET_IP}
api-int.${CLUSTER_NAME} IN A ${api_vip}
*.apps.${CLUSTER_NAME} IN A ${ingress_vip}"
fi

if [ "${ipv6_enabled:-}" == "true" ]; then
  # shellcheck disable=SC2154
  if [ ${#api_vip_v6} -eq 0 ] || [ ${#ingress_vip_v6} -eq 0 ]; then
    echo "Unable to parse IPv6 VIPs"
    exit 1
  fi

  DNS_FORWARD="${DNS_FORWARD}
provisioner.${CLUSTER_NAME} IN AAAA ${INTERNAL_NET_IPV6}
api.${CLUSTER_NAME} IN AAAA ${api_vip_v6}
api-int.${CLUSTER_NAME} IN AAAA ${api_vip_v6}
*.apps.${CLUSTER_NAME} IN AAAA ${ingress_vip_v6}"
fi

DNS_REVERSE_INTERNAL=";DO NOT EDIT; BEGIN $CLUSTER_NAME"

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#name} -eq 0 ] || [ ${#ip} -eq 0 ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi

  if [ "${ipv4_enabled:-}" == "true" ]; then
    DNS_FORWARD="${DNS_FORWARD}
${name}.${CLUSTER_NAME} IN A ${ip}"
    DNS_REVERSE_INTERNAL="${DNS_REVERSE_INTERNAL}
$(echo "${ip}." | ( rip=""; while read -r -d . b; do rip="$b${rip+.}${rip}"; done; echo "$rip" ))in-addr.arpa. IN PTR ${name}.${CLUSTER_NAME}.${BASE_DOMAIN}."
  fi

  if [ "${ipv6_enabled:-}" == "true" ]; then
    # shellcheck disable=SC2154
    if [ ${#ipv6} -eq 0 ]; then
      echo "Error when parsing the Bare Metal Host metadata"
      exit 1
    fi
    DNS_FORWARD="${DNS_FORWARD}
${name}.${CLUSTER_NAME} IN AAAA ${ipv6}"

    expanded_ipv6=$(printf "%s" "$ipv6" | awk -F ':' '{for (i=1; i<=NF; i++) printf("%04s", $i); print ""}')
    reversed_ipv6=$(echo "$expanded_ipv6" | rev)
    reversed_ipv6_with_dots=$(echo "$reversed_ipv6" | sed 's/\(.\{1\}\)/\1./g')
    reversed_ipv6="${reversed_ipv6_with_dots}ip6.arpa."
    DNS_REVERSE_INTERNAL="${DNS_REVERSE_INTERNAL}
$reversed_ipv6 IN PTR ${name}.${CLUSTER_NAME}.${BASE_DOMAIN}."
  fi
done


DNS_REVERSE_INTERNAL="${DNS_REVERSE_INTERNAL}
;DO NOT EDIT; END $CLUSTER_NAME"
DNS_FORWARD="${DNS_FORWARD}
;DO NOT EDIT; END $CLUSTER_NAME"

echo "Installing the following forward dns:"
echo -e "$DNS_FORWARD"

echo "Installing the following reverse dns:"
echo -e "$(echo -e "$DNS_REVERSE_INTERNAL" | sed "s/${BASE_DOMAIN}/BASE_DOMAIN/" )"

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "'${DNS_FORWARD}'" "'${DNS_REVERSE_INTERNAL}'" << 'EOF'
set -o nounset
set -o errexit

DNS_FORWARD=${1}
DNS_REVERSE_INTERNAL=${2}

echo -e "${DNS_FORWARD}" >> /opt/bind9_zones/zone
echo -e "${DNS_REVERSE_INTERNAL}" >> /opt/bind9_zones/internal_zone.rev

echo "Increasing the zones serial"
sed -i "s/^.*; serial/$(date +%s); serial/" /opt/bind9_zones/{zone,internal_zone.rev}
podman exec bind9 rndc reload
podman exec bind9 rndc flush
EOF
