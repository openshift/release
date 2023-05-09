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

function mac2ipv6() {
    local mac="$1" ; \
    echo "$mac" | \
    tr '-' ':' | \
    tr '[:upper:]' '[:lower:]' | \
    awk -F: '{printf "fe80::%s%x%s:%sff:fe%s:%s%s\n", substr($1,1,1), xor(strtonum("0x"substr($1,2,1)),2), $2, $3, $4, $5, $6}'
}

function reverseIp6() {
    echo "$1" | awk -F: 'BEGIN {OFS=""; }{addCount = 9 - NF; for(i=1; i<=NF;i++){if(length($i) == 0){ for(j=1;j<=addCount;j++){$i = ($i "0000");} } else { $i = substr(("0000" $i), length($i)+5-4);}}; print}' | rev | sed -e "s/./&./g"
}


# shellcheck disable=SC1090
. <(yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")' < "${SHARED_DIR}"/external_vips.yaml)

# shellcheck disable=SC2154
if [ ${#api_vip} -eq 0 ] || [ ${#ingress_vip} -eq 0 ]; then
  echo "Unable to parse VIPs"
  exit 1
fi
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
DNS_FORWARD=";DO NOT EDIT; BEGIN $CLUSTER_NAME
api.${CLUSTER_NAME} IN A ${api_vip}
provisioner.${CLUSTER_NAME} IN A ${INTERNAL_NET_IP}
api-int.${CLUSTER_NAME} IN A ${api_vip}
*.apps.${CLUSTER_NAME} IN A ${ingress_vip}"

DNS_REVERSE_INTERNAL=";DO NOT EDIT; BEGIN $CLUSTER_NAME"

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  echo "$bmhost"
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#name} -eq 0 ] || [ ${#ip} -eq 0 ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi
  # shellcheck disable=SC2154
  IP6=$(mac2ipv6 "${mac}")
  echo "macaddress to ip6: ${IP6}" 
  DNS_FORWARD="${DNS_FORWARD}
${name}.${CLUSTER_NAME} IN A ${ip}
${name}.${CLUSTER_NAME} IN AAAA ${IP6}
api.${CLUSTER_NAME} IN AAAA ${IP6}
api-int.${CLUSTER_NAME} IN AAAA ${IP6}
*.apps.${CLUSTER_NAME} IN AAAA ${IP6}"
  DNS_REVERSE_INTERNAL="${DNS_REVERSE_INTERNAL}
$(echo "${IP6}." | ( rip=""; while read -r -d . b; do rip="$b${rip+.}${rip}"; done; echo "$rip" ))in-addr.arpa. IN PTR ${name}.${CLUSTER_NAME}.${BASE_DOMAIN}.
$("$(reverseIp6 "${IP6}")")ip6.arpa. IN PTR ${name}.${CLUSTER_NAME}.${BASE_DOMAIN}."
done

# TODO verify if the installation works with no external reverse dns entries
# TODO add ipv6 (single and dual stack?)

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
docker start bind9
docker exec bind9 rndc reload
docker exec bind9 rndc flush
EOF
